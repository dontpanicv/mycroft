import AppKit
import ApplicationServices
import CoreGraphics

/// The real permission calls. Never used by the tests.
public final class SystemPermissions: PermissionSystem {
    /// A command that prints `PermissionsReport` JSON from a fresh process (this executable's
    /// `permissions --json --in-process`). Screen Recording's answer is cached for a process's lifetime, so polling
    /// in-process would never see the grant. A child keeps the same responsible app, so TCC answers for it.
    public var freshCheck: [String]?

    public init(freshCheck: [String]? = nil) {
        self.freshCheck = freshCheck
    }

    /// This process's own answer.
    public static func inProcess() -> PermissionState {
        PermissionState(accessibility: AXIsProcessTrusted(), screenRecording: CGPreflightScreenCaptureAccess())
    }

    public func current() -> PermissionState {
        guard let freshCheck, let report = Self.run(freshCheck) else { return Self.inProcess() }
        return report.state
    }

    public func promptAccessibility() {
        // "AXTrustedCheckOptionPrompt" is the value of kAXTrustedCheckOptionPrompt.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public func promptScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    public func openSettings(_ pane: SettingsPane) {
        NSWorkspace.shared.open(pane.url)
    }

    public func sleep(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    static func run(_ command: [String], timeout: TimeInterval = 5) -> PermissionsReport? {
        guard let executable = command.first else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return try? JSONDecoder().decode(PermissionsReport.self, from: data)
    }
}
