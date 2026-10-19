import Foundation
import Testing
@testable import DesktopCore

/// Scripted readings instead of TCC: nothing here prompts or opens System Settings.
final class FakePermissions: PermissionSystem, @unchecked Sendable {
    /// Returned by successive `current()` calls; the last one repeats.
    var readings: [PermissionState]
    private var index = 0
    private(set) var events: [String] = []
    private(set) var slept: TimeInterval = 0

    init(_ readings: [PermissionState]) { self.readings = readings }

    func current() -> PermissionState {
        let reading = readings[min(index, readings.count - 1)]
        index += 1
        return reading
    }

    func promptAccessibility() { events.append("prompt accessibility") }
    func promptScreenRecording() { events.append("prompt screen recording") }
    func openSettings(_ pane: SettingsPane) { events.append("open \(pane.rawValue)") }
    func sleep(_ seconds: TimeInterval) { slept += seconds }
}

func state(_ accessibility: Bool, _ screenRecording: Bool) -> PermissionState {
    PermissionState(accessibility: accessibility, screenRecording: screenRecording)
}

@Suite struct PermissionsTests {
    /// A clock that advances only when the fake sleeps.
    func run(_ system: FakePermissions, only: [Permission] = Permission.allCases, wait: TimeInterval) -> PermissionState {
        let start = Date(timeIntervalSince1970: 0)
        return PermissionFlow.request(system, only: only, wait: wait, poll: 1, now: { start.addingTimeInterval(system.slept) })
    }

    @Test func grantedAlreadyAsksNothing() {
        let system = FakePermissions([state(true, true)])
        #expect(run(system, wait: 60) == state(true, true))
        #expect(system.events.isEmpty)
        #expect(system.slept == 0)
    }

    /// One prompt at a time: Screen Recording is asked for only once Accessibility is granted.
    @Test func asksForScreenRecordingOnlyOnceAccessibilityIsGranted() {
        let system = FakePermissions([state(false, false), state(false, false), state(true, false), state(true, false), state(true, true)])
        #expect(run(system, wait: 60) == state(true, true))
        #expect(system.events == [
            "prompt accessibility", "open Privacy_Accessibility", "prompt screen recording", "open Privacy_ScreenCapture",
        ])
        #expect(system.slept == 4)
    }

    @Test func neverAsksForScreenRecordingWhileAccessibilityIsMissing() {
        let system = FakePermissions([state(false, false)])
        #expect(run(system, wait: 5) == state(false, false))
        #expect(system.events == ["prompt accessibility", "open Privacy_Accessibility"])
    }

    @Test func asksForOnlyTheOneNamed() {
        let screen = FakePermissions([state(false, false), state(false, true)])
        #expect(run(screen, only: [.screenRecording], wait: 60) == state(false, true))
        #expect(screen.events == ["prompt screen recording", "open Privacy_ScreenCapture"])
        let accessibility = FakePermissions([state(false, false), state(true, false)])
        #expect(run(accessibility, only: [.accessibility], wait: 60) == state(true, false))
        #expect(accessibility.events == ["prompt accessibility", "open Privacy_Accessibility"])
        #expect(Permission(rawValue: "screen-recording") == .screenRecording)
    }

    @Test func onlyScreenRecordingMissingOpensItsPaneAtOnce() {
        let system = FakePermissions([state(true, false), state(true, true)])
        #expect(run(system, wait: 60).allGranted)
        #expect(system.events == ["prompt screen recording", "open Privacy_ScreenCapture"])
    }

    @Test func onlyAccessibilityMissing() {
        let system = FakePermissions([state(false, true), state(true, true)])
        #expect(run(system, wait: 60).allGranted)
        #expect(system.events == ["prompt accessibility", "open Privacy_Accessibility"])
    }

    @Test func givesUpAfterTheWait() {
        let system = FakePermissions([state(false, false)])
        #expect(run(system, wait: 5) == state(false, false))
        #expect(system.slept == 5)
        let none = FakePermissions([state(false, true)])
        #expect(run(none, wait: 0) == state(false, true))
        #expect(none.slept == 0)
        #expect(none.events == ["prompt accessibility", "open Privacy_Accessibility"])
    }

    @Test func settingsURLs() {
        #expect(SettingsPane.accessibility.url.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        #expect(SettingsPane.screenRecording.url.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    @Test func reportJSON() throws {
        let report = PermissionsReport(state: state(true, false), bundleId: handsDesktopBundleId,
                                       executable: "/Users/me/Applications/Mycroft Hands.app/Contents/MacOS/hands-desktop",
                                       source: "self")
        let text = String(decoding: report.json(), as: UTF8.self)
        #expect(text == #"{"accessibility":true,"bundleId":"dev.mycroft.hands-desktop","#
                + #""executable":"/Users/me/Applications/Mycroft Hands.app/Contents/MacOS/hands-desktop","#
                + #""screenRecording":false,"source":"self","version":"\#(handsDesktopVersion)"}"#)
        let decoded = try JSONDecoder().decode(PermissionsReport.self, from: report.json())
        #expect(decoded == report)
        #expect(decoded.state == state(true, false))
        #expect(!decoded.state.allGranted)
    }

    @Test func socketClientPingsAHelper() throws {
        let backend = FakeBackend()
        backend.canRecordScreen = false
        let service = DesktopService(backend: backend, settleDelay: 0)
        let server = SocketServer(path: temporarySocketPath()) { service.handle(line: $0) }
        try server.start()
        defer { server.stop() }
        let ping = try #require(SocketClient.ping(path: server.path))
        #expect(ping == PingResult(trusted: true, screenRecording: false))
        #expect(SocketClient.ping(path: temporarySocketPath(), timeout: 0.5) == nil)
    }

    /// The app's Info.plist (embedded in the binary and copied into Mycroft Hands.app) matches the code.
    @Test func infoPlistMatchesTheContract() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/hands-desktop/Info.plist")
        let plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        #expect(plist["CFBundleIdentifier"] as? String == handsDesktopBundleId)
        #expect(plist["CFBundleShortVersionString"] as? String == handsDesktopVersion)
        #expect(plist["CFBundleVersion"] as? String == handsDesktopVersion)
        #expect(plist["CFBundleName"] as? String == "Mycroft Hands")
        #expect(plist["CFBundleExecutable"] as? String == "hands-desktop")
        #expect(plist["LSUIElement"] as? Bool == true)
        #expect(plist["NSAccessibilityUsageDescription"] is String)
        #expect(plist["NSScreenCaptureUsageDescription"] is String)
    }
}
