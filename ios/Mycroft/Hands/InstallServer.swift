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
/// While the Add Machine screen is open, the phone listens on every network it is on (Wi-Fi, Tailscale, NetBird…)
/// for a short command that can be typed by hand:
///
///     curl -fsS IP:8484/CODE | sh
///
/// That fetch is plain HTTP, so it trusts the network path. Everything after it (the binaries and the pairing) goes
/// over HTTPS pinned to a fresh self-signed certificate, and the pinned form of the command is offered too, for
/// networks you don't trust:
///
///     curl -fsSLk --pinnedpubkey sha256//PIN https://IP:8485/CODE | sh
@Observable
final class InstallServer {
    enum State: Equatable {
        case starting
        case waiting
        case paired(Machine)
        case failed(String)
    }

    private(set) var state: State = .starting
    /// Where a computer could reach this phone, nearest first.
    private(set) var addresses: [LocalNetwork.Address] = []
    /// The address the commands use: the user's pick, else the first.
    var chosen: String?
    private(set) var expiresAt = Date.now.addingTimeInterval(600)

    @ObservationIgnored private var web: NWListener?
    @ObservationIgnored private var secure: NWListener?
    @ObservationIgnored private var code = ""
    @ObservationIgnored private var pin = ""
    @ObservationIgnored private var misses = 0
    @ObservationIgnored private var used = false
    @ObservationIgnored private var onPair: ((Machine) async throws -> Void)?
    @ObservationIgnored private let log = Logger(subsystem: "dev.mycroft", category: "install")
    private let queue = DispatchQueue(label: "dev.mycroft.install")

    /// No 0/o, 1/i/l: easy to read off the screen and type.
    static let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
    static let codeLength = 6
    /// Fixed so the command is easy to remember and a tailnet ACL can allow it; any free port if they're taken.
    static let ports: (web: UInt16, secure: UInt16) = (8484, 8485)
    /// Wrong codes tolerated before the server stops, so the code can't be guessed.
    static let maxMisses = 100

    var address: LocalNetwork.Address? { addresses.first { $0.ip == chosen } ?? addresses.first }
    private(set) var webPort: UInt16?
    private(set) var securePort: UInt16?

    /// The short command for `ip`, to paste or type.
    func command(for ip: String) -> String {
        guard state == .waiting, let webPort else { return "" }
        return "curl -fsS \(Self.urlHost(ip)):\(webPort)/\(code) | sh"
    }

    /// The same install with curl pinned to this phone's certificate: safe on any network.
    func pinnedCommand(for ip: String) -> String {
        guard state == .waiting, let securePort else { return "" }
        return "curl -fsSLk --pinnedpubkey sha256//\(pin) https://\(Self.urlHost(ip)):\(securePort)/\(code) | sh"
    }

    var command: String { address.map { command(for: $0.ip) } ?? "" }
    var pinnedCommand: String { address.map { pinnedCommand(for: $0.ip) } ?? "" }

    /// Starts serving. `prefer` picks the first address on that network (the user's last pick); `onPair` stores the
    /// machine. The server stops after the first successful pairing.
    func start(prefer network: String? = nil, onPair: @escaping (Machine) async throws -> Void) {
        self.onPair = onPair
        do {
            addresses = LocalNetwork.addresses()
            guard !addresses.isEmpty else {
                throw InstallError("This iPhone isn't on a network a computer could reach. Join Wi-Fi, or turn on Tailscale or NetBird.")
            }
            chosen = addresses.first { $0.network == network }?.ip
            code = String((0..<Self.codeLength).map { _ in Self.alphabet.randomElement()! })
            let identity = try InstallIdentity.make()
            pin = identity.pin
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity.identity)!)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            listen(secure: false, port: Self.ports.web, parameters: .tcp)
            listen(secure: true, port: Self.ports.secure, parameters: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        web?.cancel()
        secure?.cancel()
        web = nil
        secure = nil
    }

    /// Listens on `port`, or on any free port when it's taken.
    private func listen(secure isSecure: Bool, port: UInt16?, parameters: NWParameters) {
        do {
            let listener = try port.map { try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: $0)!) }
                ?? NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection, secure: isSecure) }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] newState in
                Task { @MainActor in
                    guard let self, let listener else { return }
                    switch newState {
                    case .ready:
                        if isSecure { self.securePort = listener.port?.rawValue } else { self.webPort = listener.port?.rawValue }
                        if self.webPort != nil, self.securePort != nil, self.state == .starting {
                            self.expiresAt = .now.addingTimeInterval(600)
                            self.state = .waiting
                        }
                    case .failed(let error) where port != nil:
                        self.log.info("port \(port ?? 0) unavailable (\(error)); using any free port")
                        listener.cancel()
                        self.listen(secure: isSecure, port: nil, parameters: parameters)
                    case .failed(let error):
                        self.state = .failed(error.localizedDescription)
                    default:
                        break
                    }
                }
            }
            listener.start(queue: queue)
            if isSecure { secure = listener } else { web = listener }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection, secure: Bool) {
        connection.start(queue: queue)
        receive(connection, secure: secure, buffer: Data())
    }

    private func receive(_ connection: NWConnection, secure: Bool, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = HTTPRequest(parsing: buffer) {
                    let response = await self.handle(request, secure: secure, on: connection)
                    Self.respond(response.serialized(), on: connection, queue: self.queue)
                } else if complete || error != nil || buffer.count > 1_000_000 {
                    connection.cancel()
                } else {
                    self.receive(connection, secure: secure, buffer: buffer)
                }
            }
        }
    }

    /// The plain-HTTP listener serves only the script; the rest needs the pinned one.
    private func handle(_ request: HTTPRequest, secure: Bool, on connection: NWConnection) async -> HTTPResponse {
        guard Date.now < expiresAt, state == .waiting || used else { return .status(404) }
        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.first == code else {
            misses += 1
            if misses >= Self.maxMisses, !used {
                state = .failed("Too many wrong setup codes reached this iPhone, so it stopped serving the install. Start again.")
                stop()
            }
            return .status(404)
        }
        switch (request.method, parts.count > 1 ? parts[1] : nil) {
        case ("GET", nil):
            // Point the script's downloads at the address the machine used: it's the one that works.
            let host = request.host ?? Self.host(of: connection.currentPath?.localEndpoint) ?? address?.ip ?? ""
            guard let script = installScript(host: host) else { return .status(500, "install script missing from the app") }
            return HTTPResponse(status: 200, contentType: "text/x-shellscript", body: Data(script.utf8))
        case _ where !secure:
            return .status(404, "use the address and port in the script")
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
            return await pair(request.body, from: Self.host(of: connection.endpoint))
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

    private func installScript(host: String) -> String? {
        guard let url = Bundle.main.url(forResource: "phone-install", withExtension: "sh"),
            var script = try? String(contentsOf: url, encoding: .utf8),
            let securePort
        else { return nil }
        script = script.replacingOccurrences(of: "@BASE@", with: "https://\(Self.urlHost(host)):\(securePort)/\(code)")
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

    /// Sends the whole response, then closes gracefully. `.finalMessage` closes our side (TLS close_notify, FIN) only
    /// after every byte is sent; cancelling right after `contentProcessed` instead tore the connection down while a
    /// large body was still in flight over Wi-Fi, and curl reported "transfer closed with N bytes remaining".
    nonisolated static func respond(_ data: Data, on connection: NWConnection, queue: DispatchQueue) {
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            // Release the connection once the client has closed its side too, or after a generous timeout.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in connection.cancel() }
            queue.asyncAfter(deadline: .now() + 60) { connection.cancel() }
        })
    }

    /// An endpoint's address as text, without an IPv6 zone, and IPv4-mapped addresses as plain IPv4.
    nonisolated static func host(of endpoint: NWEndpoint?) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        var text = "\(host)".split(separator: "%").first.map(String.init) ?? ""
        if text.hasPrefix("::ffff:"), text.contains(".") { text.removeFirst("::ffff:".count) }
        return text.isEmpty ? nil : text
    }

    /// An address as it goes in a URL: IPv6 in brackets.
    nonisolated static func urlHost(_ ip: String) -> String { ip.contains(":") ? "[\(ip)]" : ip }
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

/// The phone's addresses a computer could reach it on.
nonisolated enum LocalNetwork {
    struct Address: Equatable, Sendable {
        /// "Wi-Fi", "Tailscale", "NetBird", "VPN", "Personal Hotspot", "Ethernet", or the interface's name.
        let network: String
        let ip: String
    }

    /// IPv4 addresses, nearest network first: they're short enough to type. Cellular is left out (carriers don't
    /// let connections in), and so are link-local and Apple's peer-to-peer interfaces.
    static func addresses() -> [Address] {
        var interfaces: [(name: String, ip: String, v6: Bool)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr,
                [UInt8(AF_INET), UInt8(AF_INET6)].contains(address.pointee.sa_family),
                interface.ifa_flags & UInt32(IFF_UP) != 0, interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            interfaces.append((String(cString: interface.ifa_name), String(cString: host), address.pointee.sa_family == UInt8(AF_INET6)))
        }
        return classify(interfaces)
    }

    /// Names each IPv4 address after its network and sorts them. Tailscale and NetBird both use 100.64.0.0/10;
    /// Tailscale's tunnel also carries an IPv6 address in fd7a:115c:a1e0::/48.
    static func classify(_ interfaces: [(name: String, ip: String, v6: Bool)]) -> [Address] {
        let order = ["Wi-Fi", "Ethernet", "Tailscale", "NetBird", "VPN", "Personal Hotspot"]
        var found: [Address] = []
        for (name, ip, v6) in interfaces where !v6 && !ip.hasPrefix("169.254.") && !found.contains(where: { $0.ip == ip }) {
            let network: String
            if name == "en0" {
                network = "Wi-Fi"
            } else if name.hasPrefix("en") {
                network = "Ethernet"
            } else if name.hasPrefix("bridge") {
                network = "Personal Hotspot"
            } else if name.hasPrefix("utun") {
                if !isCarrierGrade(ip) {
                    network = "VPN"
                } else if interfaces.contains(where: { $0.name == name && $0.ip.lowercased().hasPrefix("fd7a:115c:a1e0:") }) {
                    network = "Tailscale"
                } else {
                    network = "NetBird"
                }
            } else if ["pdp_ip", "awdl", "llw", "anpi", "ap", "ipsec"].contains(where: name.hasPrefix) {
                // Cellular, Apple's peer-to-peer links, and the carrier's Wi-Fi calling tunnels.
                continue
            } else {
                network = name
            }
            found.append(Address(network: network, ip: ip))
        }
        return found.enumerated().sorted { a, b in
            let (x, y) = (order.firstIndex(of: a.element.network) ?? order.count, order.firstIndex(of: b.element.network) ?? order.count)
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    /// 100.64.0.0/10, the shared address space Tailscale and NetBird hand out.
    static func isCarrierGrade(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }
}

// MARK: - Minimal HTTP/1.1

nonisolated struct HTTPRequest {
    var method: String
    var path: String
    /// The Host header without its port, when it is a plain hostname or IP address (it goes into the script).
    var host: String?
    var body: Data

    init?(parsing data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
            let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let start = lines.first?.split(separator: " ") ?? []
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        let length = headers["content-length"].flatMap { Int($0) } ?? 0
        host = headers["host"].flatMap(Self.hostname)
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
        method = String(start[0])
        path = String(start[1].split(separator: "?").first ?? "")
        body = data.subdata(in: bodyStart..<(bodyStart + length))
    }

    /// `host`, `host:port`, `[v6]` or `[v6]:port` → the host, if it has nothing but letters, digits, `.`, `-` and `:`.
    static func hostname(_ header: String) -> String? {
        var host = Substring(header)
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return nil }
            host = host[host.index(after: host.startIndex)..<close]
        } else if host.filter({ $0 == ":" }).count == 1 {
            host = host.prefix { $0 != ":" }
        }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        guard !host.isEmpty, host.count <= 253, host.allSatisfy(allowed.contains), !host.hasPrefix("-") else { return nil }
        return String(host)
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
