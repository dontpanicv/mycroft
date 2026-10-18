import Darwin
import Foundation
@testable import DesktopCore

/// A backend with no Accessibility, AppKit or event calls: it returns a scripted snapshot and records actions.
final class FakeBackend: DesktopBackend, @unchecked Sendable {
    struct Handle: ElementHandle, Equatable { let id: String }

    var isTrusted = true
    var canRecordScreen = true
    /// What `screenshot` returns: a scripted PNG, never a real capture.
    var screenshotResult = Screenshot(png: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]), width: 1600, height: 1000)
    var screenshotError: Error?
    private(set) var screenshotWidths: [Int] = []
    var target = TargetApp(pid: 4242, name: "Notes", bundleId: "com.apple.Notes")
    var window: String? = "Shopping list"
    var elements: [SnapshotElement] = FakeBackend.notesElements()
    var available = Available(apps: ["Notes", "Safari", "Terminal"], folders: ["Desktop", "Documents", "Downloads"], sites: [],
                              menus: ["File > New Note", "Format > Bold"])
    var observeError: Error?
    var performError: Error?
    /// Returned by successive `fingerprint` calls; the last one repeats.
    var fingerprints: [ScreenFingerprint] = [.empty]
    private var fingerprintIndex = 0

    private(set) var observedApps: [String?] = []
    private(set) var observedLimits: [Int] = []
    private(set) var actions: [BackendAction] = []
    private(set) var scopes: [FingerprintScope] = []
    var performed: [String] { actions.map(\.summary) }

    static func element(_ id: String, role: String = "button", label: String, value: String? = nil, place: Place = .content,
                        operations: [ElementOperation] = [.press]) -> SnapshotElement {
        SnapshotElement(role: role, label: label, value: value, place: place, operations: operations, handle: Handle(id: id))
    }

    static func notesElements() -> [SnapshotElement] {
        [
            element("new-note", label: "New Note", place: .toolbar),
            element("body", role: "text area", label: "Note body", value: "Milk", operations: [.type, .focus]),
            element("row", role: "row", label: "Groceries", place: .sidebar, operations: [.select, .click]),
            element("caption", role: "text", label: "Updated today", operations: [.click]),
        ]
    }

    func observe(app: String?, maxElements: Int) throws -> Snapshot {
        observedApps.append(app)
        observedLimits.append(maxElements)
        if let observeError { throw observeError }
        return Snapshot(target: target, window: window, otherWindows: 2, elements: elements, available: available, secureInputActive: false)
    }

    func fingerprint(_ scope: FingerprintScope) -> ScreenFingerprint {
        scopes.append(scope)
        let value = fingerprints[min(fingerprintIndex, fingerprints.count - 1)]
        fingerprintIndex += 1
        return value
    }

    func screenshot(maxWidth: Int) throws -> Screenshot {
        screenshotWidths.append(maxWidth)
        if let screenshotError { throw screenshotError }
        return screenshotResult
    }

    func perform(_ action: BackendAction) throws -> String {
        actions.append(action)
        if let performError { throw performError }
        return "Did \(action.summary)"
    }
}

func fingerprint(_ window: String, count: Int = 3) -> ScreenFingerprint {
    ScreenFingerprint(pid: 4242, window: window, windowFrame: "0,0/800x600", focused: nil, elementCount: count, digest: 1)
}

/// Encodes and decodes JSON objects for comparisons that ignore key order.
func jsonObject(_ data: Data) -> NSDictionary {
    (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary ?? [:]
}

func jsonObject(_ text: String) -> NSDictionary { jsonObject(Data(text.utf8)) }

func line(_ text: String) -> Data { Data(text.utf8) }

/// A blocking newline-delimited JSON client for the socket tests.
final class LineClient {
    let fd: Int32
    private var buffer = Data()

    struct Failure: Error, CustomStringConvertible { let description: String }

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "socket failed") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            close(fd)
            throw Failure(description: "connect failed: \(String(cString: strerror(errno)))")
        }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close(fd) }

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// The next line, or nil on timeout or end of stream.
    func readLine() -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return String(decoding: line, as: UTF8.self)
            }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}

/// A short socket path: sockaddr_un holds 104 bytes, and the default temporary directory is long.
func temporarySocketPath() -> String {
    "/tmp/hd-test-\(UUID().uuidString.prefix(8)).sock"
}
