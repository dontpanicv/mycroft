import AppIntents

struct RunProbeIntent: LongRunningIntent, CancellableIntent {
    static var title: LocalizedStringResource = "Run JavaScript background spike"
    static var supportedModes: IntentModes { .background }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Seconds", default: 120) var seconds: Int
    @Parameter(title: "Report progress", default: true) var reportsProgress: Bool

    init() {}
    init(seconds: Int, reportsProgress: Bool) {
        self.seconds = seconds
        self.reportsProgress = reportsProgress
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        Journal.shared.emit("intent_entered", ["seconds": seconds, "reportsProgress": reportsProgress])
        do {
            try await performBackgroundTask {
                try await Runner.shared.run(mode: "long_running_intent", seconds: seconds,
                    progress: progress, reportsProgress: reportsProgress)
            } onCancel: { reason in
                Task { @MainActor in
                    Journal.shared.emit("intent_cancelled", ["reason": reason.debugDescription])
                    Runner.shared.cancel()
                }
            }
            Journal.shared.emit("intent_completed")
            return .result(value: "JavaScript task completed")
        } catch {
            Journal.shared.error("intent_error", error)
            throw error
        }
    }
}

struct ProbeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RunProbeIntent(), phrases: ["Run background spike in \(.applicationName)"],
            shortTitle: "Background spike", systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(intent: RunProbeIntent(seconds: 600, reportsProgress: true),
            phrases: ["Run ten minute spike in \(.applicationName)"],
            shortTitle: "Ten minute run", systemImageName: "hourglass")
        AppShortcut(intent: RunProbeIntent(seconds: 120, reportsProgress: false),
            phrases: ["Run without progress in \(.applicationName)"],
            shortTitle: "No progress run", systemImageName: "pause.circle")
        AppShortcut(intent: PlainProbeIntent(), phrases: ["Run plain intent in \(.applicationName)"],
            shortTitle: "Plain intent control", systemImageName: "circle.dashed")
    }
}

// Negative control: same work and invocation path, without a runtime extension request.
struct PlainProbeIntent: AppIntent {
    static var title: LocalizedStringResource = "Plain intent control"
    static var supportedModes: IntentModes { .background }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @MainActor
    func perform() async throws -> some IntentResult {
        Journal.shared.emit("plain_intent_entered")
        try await Runner.shared.run(mode: "plain_intent_control", seconds: 120,
                                    progress: nil, reportsProgress: false)
        Journal.shared.emit("plain_intent_completed")
        return .result()
    }
}
