import Foundation

// The two privacy permissions the helper needs, Accessibility (ui.observe, ui.act) and Screen Recording
// (ui.screenshot), and the flow that asks for them. Only the user can grant either; the helper only triggers macOS's
// own prompts and opens the right System Settings pane.
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

public enum PermissionFlow {
    /// Prompts for whatever is missing and opens its System Settings pane, then polls every `poll` seconds until both
    /// are granted or `wait` seconds pass. The Accessibility pane opens first; the Screen Recording pane opens once
    /// Accessibility is granted (or at once when only Screen Recording is missing). Returns the last reading.
    @discardableResult
    public static func request(_ system: PermissionSystem, wait: TimeInterval, poll: TimeInterval = 1,
                               now: () -> Date = Date.init, log: (String) -> Void = { _ in }) -> PermissionState {
        var state = system.current()
        log("accessibility \(granted(state.accessibility)), screen recording \(granted(state.screenRecording))")
        if state.allGranted { return state }
        var openedScreenRecording = false
        if !state.accessibility {
            system.promptAccessibility()
            system.openSettings(.accessibility)
            log("asked for Accessibility and opened its System Settings pane")
        }
        if !state.screenRecording {
            system.promptScreenRecording()
            log("asked for Screen Recording")
            if state.accessibility {
                system.openSettings(.screenRecording)
                openedScreenRecording = true
                log("opened the Screen Recording pane")
            }
        }
        let deadline = now().addingTimeInterval(wait)
        while !state.allGranted, now() < deadline {
            system.sleep(poll)
            let next = system.current()
            if next != state {
                log("accessibility \(granted(next.accessibility)), screen recording \(granted(next.screenRecording))")
            }
            state = next
            if state.accessibility, !state.screenRecording, !openedScreenRecording {
                system.openSettings(.screenRecording)
                openedScreenRecording = true
                log("opened the Screen Recording pane")
            }
        }
        return state
    }

    static func granted(_ value: Bool) -> String { value ? "granted" : "not granted" }
}
