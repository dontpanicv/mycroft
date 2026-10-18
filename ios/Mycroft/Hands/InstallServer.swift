import CryptoKit
import Foundation
import Network
import Observation
import os
import Security
import SwiftASN1
import X509

/// Serves the one-line `hands` install from the phone (hands/docs/pairing.md §1).
///
/// While the Add Machine sheet is open, the phone runs a small HTTPS server on the LAN with a fresh self-signed
/// certificate. The command it copies pins that certificate, so only this phone can answer it:
///
///     curl -fsSLk --pinnedpubkey sha256//PIN https://IP:PORT/SETUP | sh
@Observable
final class InstallServer {
    enum State: Equatable {
        case starting
        case waiting
        case paired(Machine)
        case failed(String)
    }

    private(set) var state: State = .starting
    private(set) var command = ""
    private(set) var expiresAt = Date.now.addingTimeInterval(600)

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var setupID = ""
    @ObservationIgnored private var pin = ""
    @ObservationIgnored private var host = ""
    @ObservationIgnored private var used = false
    @ObservationIgnored private var onPair: ((Machine) async throws -> Void)?
    @ObservationIgnored private let log = Logger(subsystem: "dev.mycroft", category: "install")
    private let queue = DispatchQueue(label: "dev.mycroft.install")

    static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")

    /// Starts serving. `onPair` stores the machine; the server stops after the first successful pairing.
    func start(onPair: @escaping (Machine) async throws -> Void) {
        self.onPair = onPair
        do {
            guard let address = LocalNetwork.wifiAddress() else { throw InstallError("This iPhone has no Wi-Fi address. Join the same network as the computer.") }
            host = address
            setupID = String((0..<8).map { _ in Self.alphabet.randomElement()! })
            let identity = try InstallIdentity.make()
            pin = identity.pin
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity.identity)!)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            let listener = try NWListener(using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state) }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func listenerChanged(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            guard let port = listener?.port?.rawValue else { return }
            command = "curl -fsSLk --pinnedpubkey sha256//\(pin) https://\(host):\(port)/\(setupID) | sh"
            expiresAt = .now.addingTimeInterval(600)
            state = .waiting
        case .failed(let error):
            state = .failed(error.localizedDescription)
        default:
            break
        }
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = HTTPRequest(parsing: buffer) {
                    let source = Self.sourceAddress(of: connection)
                    let response = await self.handle(request, from: source)
                    connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
                } else if complete || error != nil || buffer.count > 1_000_000 {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
            }
        }
    }

    private func handle(_ request: HTTPRequest, from source: String?) async -> HTTPResponse {
        guard Date.now < expiresAt else { return .status(404) }
        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.first == setupID else { return .status(404) }
        switch (request.method, parts.count > 1 ? parts[1] : nil) {
        case ("GET", nil):
            guard let script = installScript() else { return .status(500, "install script missing from the app") }
            return HTTPResponse(status: 200, contentType: "text/x-shellscript", body: Data(script.utf8))
        case ("GET", "MycroftHands.zip"):
            guard let url = HandsBinaries.desktopZip, let data = try? Data(contentsOf: url) else {
                return .status(404, "this build of Mycroft has no desktop helper")
            }
            return HTTPResponse(status: 200, contentType: "application/zip", body: data)
        case ("GET", let name?) where name.hasPrefix("hands-"):
            guard let url = HandsBinaries.url(name), let data = try? Data(contentsOf: url) else {
                return .status(404, "no \(name) in this build of Mycroft")
            }
            return HTTPResponse(status: 200, contentType: "application/octet-stream", body: data)
        case ("POST", "pair"):
            return await pair(request.body, from: source)
        default:
            return .status(404)
        }
    }

    private func pair(_ body: Data, from source: String?) async -> HTTPResponse {
        guard !used else { return .status(410, "this setup command was already used") }
        struct Request: Decodable {
            var name: String
            var os: String
            var arch: String
            var version: String
            var port: Int
            var certSha256: String
            var addresses: [String]?
            var hostname: String?
        }
        guard let request = try? JSONDecoder().decode(Request.self, from: body), request.certSha256.count == 64,
            (1...65535).contains(request.port)
        else { return .status(400, "bad pairing request") }
        let machine = Machine(
            name: request.name, hostname: request.hostname,
            addresses: [source].compactMap { $0 } + (request.addresses ?? []), port: request.port,
            certSha256: request.certSha256.lowercased(), os: request.os, arch: request.arch, version: request.version,
            pairedAt: .now)
        do {
            try await onPair?(machine)
            used = true
            state = .paired(machine)
            let reply = try JSONSerialization.data(withJSONObject: [
                "phoneName": PhoneIdentity.deviceName, "publicKey": try PhoneIdentity.publicKeyBase64(),
            ])
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                self.stop()
            }
            return HTTPResponse(status: 200, contentType: "application/json", body: reply)
        } catch {
            log.error("pairing failed: \(error)")
            return .status(500, "pairing failed: \(error.localizedDescription)")
        }
    }

    private func installScript() -> String? {
        guard let url = Bundle.main.url(forResource: "phone-install", withExtension: "sh"),
            var script = try? String(contentsOf: url, encoding: .utf8),
            let port = listener?.port?.rawValue
        else { return nil }
        script = script.replacingOccurrences(of: "@BASE@", with: "https://\(host):\(port)/\(setupID)")
        script = script.replacingOccurrences(of: "@PIN@", with: pin)
        for target in HandsBinaries.targets {
            let hash = HandsBinaries.sha256(target) ?? "missing"
            script = script.replacingOccurrences(of: "@SHA256_\(target.replacingOccurrences(of: "-", with: "_"))@", with: hash)
        }
        // Left unfilled when the app has no desktop helper: the script then skips it.
        if let zip = HandsBinaries.desktopZip, let data = try? Data(contentsOf: zip) {
            script = script.replacingOccurrences(of: "@SHA256_desktop@", with: data.sha256Hex)
        }
        return script
    }

    nonisolated static func sourceAddress(of connection: NWConnection) -> String? {
        guard case .hostPort(let host, _) = connection.endpoint else { return nil }
        let text = "\(host)"
        return text.split(separator: "%").first.map(String.init)
    }
}

struct InstallError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The `hands` binaries bundled in the app (hands/dist, built by hands/scripts/build-release.sh).
nonisolated enum HandsBinaries {
    static let targets = ["darwin-arm64", "darwin-x86_64", "linux-x86_64", "linux-aarch64"]

    static func url(_ name: String) -> URL? {
        guard name.hasPrefix("hands-"), targets.contains(String(name.dropFirst("hands-".count))) else { return nil }
        return Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "hands-dist")
    }

    /// Mycroft Hands.app, the macOS desktop helper (desktop/scripts/build.sh), zipped.
    static var desktopZip: URL? {
        Bundle.main.url(forResource: "MycroftHands", withExtension: "zip", subdirectory: "hands-dist")
    }

    static func sha256(_ target: String) -> String? {
        guard let url = url("hands-\(target)"), let data = try? Data(contentsOf: url) else { return nil }
        return data.sha256Hex
    }
}

/// A self-signed P-256 certificate and its keychain identity, made fresh for each install session.
nonisolated enum InstallIdentity {
    struct Made {
        let identity: SecIdentity
        /// curl's `--pinnedpubkey sha256//` value: base64 of SHA-256 over the SubjectPublicKeyInfo DER.
        let pin: String
    }

    private static let tag = Data("dev.mycroft.install.key".utf8)
    private static let label = "Mycroft install"

    static func make() throws -> Made {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName { CommonName("Mycroft hands install") }
        let now = Date()
        let certificate = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(key.publicKey),
            notValidBefore: now.addingTimeInterval(-3600), notValidAfter: now.addingTimeInterval(86400),
            issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                KeyUsage(digitalSignature: true)
                try ExtendedKeyUsage([.serverAuth])
            },
            issuerPrivateKey: Certificate.PrivateKey(key))
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        let der = Data(serializer.serializedBytes)

        // Replace the previous session's key and certificate.
        SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: tag] as CFDictionary)
        SecItemDelete([kSecClass: kSecClassCertificate, kSecAttrLabel: label] as CFDictionary)

        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(key.x963Representation as CFData, [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits: 256,
        ] as CFDictionary, &error) else { throw error!.takeRetainedValue() }
        try check(SecItemAdd([
            kSecClass: kSecClassKey, kSecValueRef: secKey, kSecAttrApplicationTag: tag,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary, nil))
        guard let secCertificate = SecCertificateCreateWithData(nil, der as CFData) else { throw InstallError("certificate") }
        try check(SecItemAdd([kSecClass: kSecClassCertificate, kSecValueRef: secCertificate, kSecAttrLabel: label] as CFDictionary, nil))

        var result: CFTypeRef?
        try check(SecItemCopyMatching([
            kSecClass: kSecClassIdentity, kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitAll,
        ] as CFDictionary, &result))
        let identities = (result as? [SecIdentity]) ?? []
        guard let identity = identities.first(where: { identity in
            var certificate: SecCertificate?
            SecIdentityCopyCertificate(identity, &certificate)
            return certificate.map { SecCertificateCopyData($0) as Data } == der
        }) else { throw InstallError("Could not create the install certificate's identity.") }

        let pin = Data(SHA256.hash(data: key.publicKey.derRepresentation)).base64EncodedString()
        return Made(identity: identity, pin: pin)
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw KeychainError(status: status) }
    }
}

/// The phone's Wi-Fi IPv4 address, which the copied command points at.
nonisolated enum LocalNetwork {
    static func wifiAddress() -> String? {
        var addresses: [(name: String, address: String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                interface.ifa_flags & UInt32(IFF_UP) != 0, interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            addresses.append((String(cString: interface.ifa_name), String(cString: host)))
        }
        // Wi-Fi is en0 on iPhone; the Simulator reports the Mac's interfaces.
        return addresses.first(where: { $0.name == "en0" })?.address
            ?? addresses.first(where: { $0.name.hasPrefix("en") && !$0.address.hasPrefix("169.254") })?.address
    }
}

// MARK: - Minimal HTTP/1.1

nonisolated struct HTTPRequest {
    var method: String
    var path: String
    var body: Data

    init?(parsing data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
            let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let start = lines.first?.split(separator: " ") ?? []
        guard start.count >= 2 else { return nil }
        let length = lines.dropFirst().compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
        method = String(start[0])
        path = String(start[1].split(separator: "?").first ?? "")
        body = data.subdata(in: bodyStart..<(bodyStart + length))
    }
}

nonisolated struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data

    static func status(_ code: Int, _ message: String? = nil) -> HTTPResponse {
        HTTPResponse(status: code, contentType: "text/plain", body: Data(((message ?? "not found") + "\n").utf8))
    }

    func serialized() -> Data {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 410: "Gone", 500: "Internal Server Error"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
