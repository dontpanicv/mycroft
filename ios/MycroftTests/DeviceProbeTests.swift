import Foundation
import Network
import Testing

@testable import Mycroft

/// On-device diagnostics for reaching a paired machine. Run on an iPhone with MYCROFT_PROBE="host:port:certSha256".
@Suite("Device probe")
nonisolated struct DeviceProbeTests {
    static let target = ProcessInfo.processInfo.environment["MYCROFT_PROBE"]

    @Test(.enabled(if: DeviceProbeTests.target != nil))
    func reachPairedMachine() async throws {
        let parts = try #require(Self.target?.split(separator: ":").map(String.init))
        let (host, port, cert) = (parts[0], Int(parts[1])!, parts[2])

        // 1. Plain TCP: is the Mac reachable at all from this phone?
        let tcp = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        let tcpState = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let once = Once()
            tcp.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume(returning: "ready") }
                case .waiting(let error): once.run { continuation.resume(returning: "waiting: \(error)") }
                case .failed(let error): once.run { continuation.resume(returning: "failed: \(error)") }
                default: break
                }
            }
            tcp.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { once.run { continuation.resume(returning: "timeout") } }
        }
        tcp.cancel()
        print("PROBE tcp \(host):\(port) → \(tcpState)")

        // 2. The real thing: pinned TLS + WebSocket + Ed25519 handshake + hello.
        let hosts = (ProcessInfo.processInfo.environment["MYCROFT_PROBE_HOSTS"] ?? host).split(separator: ",").map(String.init)
        let started = Date.now
        let machine = Machine(name: "probe", hostname: nil, addresses: hosts, port: port, certSha256: cert, os: "macos",
                              arch: "aarch64", version: "?", pairedAt: .now)
        do {
            let hands = try await HandsConnection.open(machine, key: PhoneIdentity.key())
            let info = await hands.info
            print("PROBE hands → ok in \(String(format: "%.2f", Date.now.timeIntervalSince(started))) s via \(hosts), home \(info?.string("home") ?? "?"), version \(info?.string("version") ?? "?")")
            await hands.close()
        } catch {
            print("PROBE hands → \(error)")
        }
    }
}

/// Runs the phone's install server for two minutes and prints its command, so downloads can be tested over Wi-Fi.
@Suite("Install server probe")
@MainActor
struct InstallServerProbeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MYCROFT_SERVE"] != nil))
    func serveInstall() async throws {
        let server = InstallServer()
        server.start { _ in }
        for _ in 0..<50 where server.command.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        print("INSTALL COMMAND: \(server.command)")
        try await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["MYCROFT_SERVE"] ?? "") ?? 120))
        server.stop()
    }
}

nonisolated private final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
