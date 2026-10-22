import CryptoKit
import Foundation
import Network
import os

/// One authenticated connection to a paired machine's `hands` listener (hands/docs/pairing.md §2).
///
/// WebSocket over TLS with the machine's certificate pinned, then the hello/auth/ready handshake, then pi-env frames
/// (hands/docs/protocol.md), one per binary message. Requests are matched to replies by id.
actor HandsConnection {
    struct Reply: @unchecked Sendable {
        let json: [String: Any]
        let payload: Data

        subscript(key: String) -> Any? { json[key] }
        func string(_ key: String) -> String? { json[key] as? String }
        func int(_ key: String) -> Int? { (json[key] as? NSNumber)?.intValue }
        func bool(_ key: String) -> Bool { (json[key] as? Bool) ?? false }
    }

    struct RemoteError: LocalizedError {
        let code: String
        let message: String
        var lost = false
        var errorDescription: String? { "\(code): \(message)" }
    }

    let machine: Machine
    /// What the daemon reported in `hello`: home, os, arch, version, features.
    private(set) var info: Reply?
    private(set) var isClosed = false

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.mycroft.hands")
    /// Output collected for requests that asked for it, until their result.
    private var output: [UInt32: Data] = [:]
    private var nextID: UInt32 = 1
    private var pending: [UInt32: CheckedContinuation<Reply, Error>] = [:]
    private var pinger: Task<Void, Never>?
    private let log = Logger(subsystem: "dev.mycroft", category: "hands")

    private init(machine: Machine, connection: NWConnection) {
        self.machine = machine
        self.connection = connection
    }

    /// Tries every address of the machine at once and keeps the first that authenticates. If none does, the error
    /// lists what happened at each address (a dead VPN address must not hide why the LAN one failed).
    static func open(_ machine: Machine, key: Curve25519.Signing.PrivateKey, timeout: Duration = .seconds(6)) async throws -> HandsConnection {
        let hosts = machine.hosts
        guard !hosts.isEmpty else { throw RemoteError(code: "unreachable", message: "\(machine.name) has no address") }
        return try await withThrowingTaskGroup(of: (String, Result<HandsConnection, Error>).self) { group in
            for host in hosts {
                group.addTask {
                    do {
                        let connection = try await HandsConnection.connect(host: host, machine: machine, timeout: timeout)
                        let hands = HandsConnection(machine: machine, connection: connection)
                        do {
                            try await hands.handshake(key: key, timeout: timeout)
                        } catch {
                            await hands.close()
                            throw error
                        }
                        return (host, .success(hands))
                    } catch {
                        return (host, .failure(error))
                    }
                }
            }
            var winner: HandsConnection?
            var failures: [String] = []
            for try await (host, result) in group {
                switch result {
                case .success(let hands):
                    if winner == nil {
                        winner = hands
                        group.cancelAll()
                    } else {
                        await hands.close()
                    }
                case .failure(let error):
                    failures.append("\(host): \(describe(error))")
                }
            }
            if let winner { return winner }
            if failures.contains(where: { $0.contains(localNetworkDenied) }) {
                throw RemoteError(code: "local_network", message: "\(localNetworkDenied). Turn it on in Settings → Privacy & Security → Local Network → Mycroft.")
            }
            throw RemoteError(code: "unreachable", message: failures.joined(separator: "; "))
        }
    }

    static let localNetworkDenied = "iOS is blocking Mycroft from the local network"

    private static func describe(_ error: Error) -> String {
        if let remote = error as? RemoteError { return remote.message }
        if error is CancellationError { return "cancelled" }
        return error.localizedDescription
    }

    private static func connect(host: String, machine: Machine, timeout: Duration) async throws -> NWConnection {
        let tls = NWProtocolTLS.Options()
        let expected = machine.certSha256
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            let leaf = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first
            let hash = leaf.map { (SecCertificateCopyData($0) as Data).sha256Hex }
            complete(hash == expected)
        }, DispatchQueue(label: "dev.mycroft.hands.tls"))
        let parameters = NWParameters(tls: tls)
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = HandsProtocol.maxFrame + 16
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        let url = URL(string: "wss://\(host.contains(":") ? "[\(host)]" : host):\(machine.port)/v1")!
        let connection = NWConnection(to: .url(url), using: parameters)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let once = OSAllocatedUnfairLock(initialState: false)
                    connection.stateUpdateHandler = { state in
                        let resume: Result<Void, Error>? = switch state {
                        case .ready: .success(())
                        case .waiting where connection.currentPath?.unsatisfiedReason == .localNetworkDenied:
                            .failure(RemoteError(code: "local_network", message: HandsConnection.localNetworkDenied))
                        case .failed(let error), .waiting(let error): .failure(error)
                        case .cancelled: .failure(CancellationError())
                        default: nil
                        }
                        guard let resume, once.withLock({ done in defer { done = true }; return !done }) else { return }
                        continuation.resume(with: resume)
                    }
                    connection.start(queue: DispatchQueue(label: "dev.mycroft.hands.connect"))
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RemoteError(code: "timeout", message: "\(host) did not answer")
            }
            defer { group.cancelAll() }
            do {
                try await withTaskCancellationHandler {
                    try await group.next()
                } onCancel: {
                    connection.cancel()  // a faster address won; stop this attempt now
                }
            } catch {
                connection.cancel()
                throw error
            }
        }
        return connection
    }

    // MARK: Handshake

    private func handshake(key: Curve25519.Signing.PrivateKey, timeout: Duration) async throws {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { await self?.close(lost: true) } }
            if case .cancelled = state { Task { await self?.close(lost: true) } }
        }
        let hello = try await receiveText()
        guard hello["type"] as? String == "hello", let nonce = hello["nonce"] as? String else {
            throw RemoteError(code: "handshake", message: "unexpected greeting")
        }
        let signature = try PhoneIdentity.authSignature(certSha256: machine.certSha256, nonce: nonce, key: key)
        try await sendText(["type": "auth", "publicKey": key.publicKey.rawRepresentation.base64EncodedString(), "signature": signature])
        let answer = try await receiveText()
        guard answer["type"] as? String == "ready" else {
            throw RemoteError(code: answer["code"] as? String ?? "unauthorized", message: "\(machine.name) refused this phone")
        }
        startReading()
        pinger = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await self?.ping()
            }
        }
        info = try await request("hello", ["protocol": HandsProtocol.version])
    }

    private func receiveText() async throws -> [String: Any] {
        let (data, _) = try await receiveMessage()
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func sendText(_ object: [String: Any]) async throws {
        try await send(try JSONSerialization.data(withJSONObject: object), opcode: .text)
    }

    // MARK: Frames

    /// Sends a request and waits for its result. Errors from the daemon throw ``RemoteError``. With `collectOutput`,
    /// the result's payload is the output the request streamed (an `exec`'s stdout and stderr, the first 16 KB).
    func request(_ op: String, _ fields: sending [String: Any] = [:], payload: Data = Data(), collectOutput: Bool = false) async throws -> Reply {
        guard !isClosed else { throw RemoteError(code: "unknown", message: "connection closed", lost: true) }
        let id = nextID
        nextID &+= 1
        var json = fields
        json["op"] = op
        let frame = try HandsProtocol.Frame(type: .request, id: id, json: json, payload: payload).encoded()
        // Stopping a run cancels the tool's task: end the wait at once and tell hands to cancel the request.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if cancelled.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = continuation
                if collectOutput { output[id] = Data() }
                Task {
                    do {
                        try await self.send(frame, opcode: .binary)
                    } catch {
                        self.fail(id, error)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id) }
        }
    }

    /// Requests cancelled before their continuation was registered.
    private var cancelled: Set<UInt32> = []

    private func cancelRequest(_ id: UInt32) async {
        guard let continuation = pending.removeValue(forKey: id) else {
            cancelled.insert(id)
            return
        }
        output.removeValue(forKey: id)
        continuation.resume(throwing: CancellationError())
        if let frame = try? HandsProtocol.Frame(type: .cancel, id: id).encoded() {
            try? await send(frame, opcode: .binary)
        }
    }

    private func fail(_ id: UInt32, _ error: Error) {
        output.removeValue(forKey: id)
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func ping() async {
        guard !isClosed, let frame = try? HandsProtocol.Frame(type: .ping, id: 0).encoded() else { return }
        try? await send(frame, opcode: .binary)
    }

    private func startReading() {
        Task { [weak self] in
            while let self, await !self.isClosed {
                do {
                    let (data, _) = try await self.receiveMessage()
                    await self.dispatch(data)
                } catch {
                    await self.close(lost: true)
                    return
                }
            }
        }
    }

    private func dispatch(_ data: Data) {
        var reader = HandsProtocol.Reader(synced: true)
        guard let frames = try? reader.feed(data) else { return }
        for frame in frames {
            switch frame.type {
            case .result:
                pending.removeValue(forKey: frame.id)?.resume(returning: Reply(json: frame.json, payload: output.removeValue(forKey: frame.id) ?? frame.payload))
            case .event:
                // A request that collects its output (the screen's quick exec) keeps the first 16 KB of it.
                if var collected = output[frame.id], frame.json["kind"] as? String == "output" {
                    collected.append(frame.payload.prefix(max(0, 16_384 - collected.count)))
                    output[frame.id] = collected
                }
            case .error:
                output.removeValue(forKey: frame.id)
                let error = RemoteError(code: frame.json["code"] as? String ?? "unknown", message: frame.json["message"] as? String ?? "")
                pending.removeValue(forKey: frame.id)?.resume(throwing: error)
            default:
                break  // pings and events (exec output) are not used: Mycroft runs commands as jobs.
            }
        }
    }

    func close(lost: Bool = false) {
        guard !isClosed else { return }
        isClosed = true
        pinger?.cancel()
        connection.cancel()
        for (_, continuation) in pending {
            continuation.resume(throwing: RemoteError(code: "unknown", message: "connection to \(machine.name) lost", lost: true))
        }
        pending.removeAll()
        output.removeAll()
    }

    // MARK: WebSocket I/O

    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode) async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func receiveMessage() async throws -> (Data, NWProtocolWebSocket.Opcode) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { data, context, _, error in
                if let error { return continuation.resume(throwing: error) }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if metadata?.opcode == .close { return continuation.resume(throwing: RemoteError(code: "closed", message: "closed", lost: true)) }
                continuation.resume(returning: (data ?? Data(), metadata?.opcode ?? .binary))
            }
        }
    }
}

/// One live connection per machine, reopened on demand after the phone slept or the network changed.
actor HandsPool {
    static let shared = HandsPool()
    private var connections: [String: HandsConnection] = [:]
    /// Connections being opened, so parallel tool calls to one machine share a single connection.
    private var opening: [String: Task<HandsConnection, Error>] = [:]

    func connection(to machine: Machine) async throws -> HandsConnection {
        if let existing = connections[machine.id], await !existing.isClosed, await existing.machine == machine {
            return existing
        }
        if let pending = opening[machine.id] { return try await pending.value }
        let task = Task { try await HandsConnection.open(machine, key: PhoneIdentity.key()) }
        opening[machine.id] = task
        defer { opening[machine.id] = nil }
        let fresh = try await task.value
        connections[machine.id] = fresh
        Task { await CuaTools.refreshCatalog(from: fresh) }
        return fresh
    }

    /// Runs `body`, reconnecting once if the connection turned out to be stale.
    func with<T: Sendable>(_ machine: Machine, _ body: @Sendable (HandsConnection) async throws -> T) async throws -> T {
        do {
            return try await body(try await connection(to: machine))
        } catch let error as HandsConnection.RemoteError where error.lost {
            connections[machine.id] = nil
            return try await body(try await connection(to: machine))
        }
    }

    func forget(_ machine: Machine) async {
        await connections.removeValue(forKey: machine.id)?.close()
    }
}
