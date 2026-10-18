import Foundation
import Network

/// iOS asks "Allow Mycroft to find devices on your local network?" the first time the app touches the LAN. Until the
/// user answers, connections to and from the LAN fail — so the Add Machine sheet asks first, by browsing for hands.
nonisolated enum LocalNetworkPermission {
    enum Status: Sendable { case granted, denied, unknown }

    /// Starts a Bonjour browse for hands (which makes iOS show its prompt) and reports what iOS decided within `wait`.
    static func request(wait seconds: Double = 30) async -> Status {
        let browser = NWBrowser(for: .bonjour(type: "_mycroft-hands._tcp", domain: nil), using: .tcp)
        let once = OneShot()
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<Status, Never>) in
            browser.stateUpdateHandler = { state in
                switch state {
                case .waiting(let error), .failed(let error):
                    if case .dns(let code) = error, code == -65570 {  // kDNSServiceErr_PolicyDenied
                        once.run { continuation.resume(returning: .denied) }
                    }
                default:
                    break
                }
            }
            browser.browseResultsChangedHandler = { results, _ in
                if !results.isEmpty { once.run { continuation.resume(returning: .granted) } }
            }
            browser.start(queue: DispatchQueue(label: "dev.mycroft.localnetwork"))
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                once.run { continuation.resume(returning: .unknown) }
            }
        }
        browser.cancel()
        return status
    }
}

nonisolated private final class OneShot: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
