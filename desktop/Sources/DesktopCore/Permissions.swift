import Foundation

// The two privacy permissions the helper needs, Accessibility (ui.observe, ui.act) and Screen Recording
// (ui.screenshot), and the flow that asks for them. Only the user can grant either; the helper only triggers macOS's
// own prompts and opens the right System Settings pane, one permission at a time.
//
// macOS attributes both to the *responsible* process. Run from Terminal, that is Terminal. So the request flow must run
// inside Mycroft Hands.app, started by launchd: `open -n "Mycroft Hands.app" --args --request-permissions`, or the
// LaunchAgent. TCC then keys the grants to the bundle id and the signing team, so they survive updates signed by the
// same team.

public struct PermissionState: Codable, Equatable, Sendable {
    public var accessibility: Bool
    public var screenRecording: Bool

    public init(accessibility: Bool, screenRecording: Bool) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
    }

    public var allGranted: Bool { accessibility && screenRecording }
}

/// What `hands-desktop permissions --json` prints.
public struct PermissionsReport: Codable, Equatable, Sendable {
    public var accessibility: Bool
    public var screenRecording: Bool
    public var version: String
    public var bundleId: String?
    public var executable: String
    /// Where the answer came from: `self` (this process's own TCC check) or `helper` (the running helper's ping, which
    /// is what counts when this process was started from a terminal).
    public var source: String

    public init(state: PermissionState, version: String = handsDesktopVersion, bundleId: String?, executable: String,
                source: String) {
        self.accessibility = state.accessibility
        self.screenRecording = state.screenRecording
        self.version = version
        self.bundleId = bundleId
        self.executable = executable
        self.source = source
    }

    public var state: PermissionState { PermissionState(accessibility: accessibility, screenRecording: screenRecording) }

    public func json() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }
}

public enum SettingsPane: String, CaseIterable, Sendable {
    case accessibility = "Privacy_Accessibility"
    case screenRecording = "Privacy_ScreenCapture"

    public var url: URL { URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")! }
}

/// The system calls of the request flow, so it can be tested without prompting anyone.
public protocol PermissionSystem: AnyObject {
    /// A fresh reading of both permissions.
    func current() -> PermissionState
    /// AXIsProcessTrustedWithOptions with the prompt option: macOS shows its Accessibility dialog.
    func promptAccessibility()
    /// CGRequestScreenCaptureAccess: macOS shows its Screen Recording dialog (once per launch).
    func promptScreenRecording()
    func openSettings(_ pane: SettingsPane)
    func sleep(_ seconds: TimeInterval)
}

/// One of the two permissions, as `--only` names it.
public enum Permission: String, CaseIterable, Sendable {
    case accessibility
    case screenRecording = "screen-recording"

    public func isGranted(in state: PermissionState) -> Bool {
        switch self {
        case .accessibility: state.accessibility
        case .screenRecording: state.screenRecording
        }
    }

    var pane: SettingsPane {
        switch self {
        case .accessibility: .accessibility
        case .screenRecording: .screenRecording
        }
    }

    var name: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        }
    }
}

public enum PermissionFlow {
    /// Asks for each of `permissions` that is missing, one at a time and in order: macOS's prompt and the System
    /// Settings pane for one, then a poll every `poll` seconds until it is granted, then the next. macOS shows one
    /// permission prompt at a time, so asking for both at once lost the second. Stops at the first permission still
    /// missing when `wait` seconds have passed. Returns the last reading.
    @discardableResult
    public static func request(_ system: PermissionSystem, only permissions: [Permission] = Permission.allCases,
                               wait: TimeInterval, poll: TimeInterval = 1, now: () -> Date = Date.init,
                               log: (String) -> Void = { _ in }) -> PermissionState {
        var state = system.current()
        log("accessibility \(granted(state.accessibility)), screen recording \(granted(state.screenRecording))")
        let deadline = now().addingTimeInterval(wait)
        for permission in permissions where !permission.isGranted(in: state) {
            switch permission {
            case .accessibility: system.promptAccessibility()
            case .screenRecording: system.promptScreenRecording()
            }
            system.openSettings(permission.pane)
            log("asked for \(permission.name) and opened its System Settings pane")
            while !permission.isGranted(in: state) {
                guard now() < deadline else { return state }
                system.sleep(poll)
                let next = system.current()
                if next != state {
                    log("accessibility \(granted(next.accessibility)), screen recording \(granted(next.screenRecording))")
                }
                state = next
            }
        }
        return state
    }

    static func granted(_ value: Bool) -> String { value ? "granted" : "not granted" }
}
