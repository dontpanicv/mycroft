import AppIntents
import Foundation
import PiDurableKit

/// "Ask Mycroft" from Shortcuts or Siri: starts a new thread and waits for the answer in the background.
struct AskMycroftIntent: LongRunningIntent, CancellableIntent {
    static var title: LocalizedStringResource { "Ask Mycroft" }
    static var description: IntentDescription { IntentDescription("Start a new Mycroft thread and get the answer.") }
    static var supportedModes: IntentModes { .background }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Request") var request: String

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let request = request
        // Foundation's Progress is thread-safe, but not marked Sendable.
        let progress = UncheckedSendable(progress)
        let answer = try await performBackgroundTask { @Sendable in
            try await Self.ask(request, progress: progress.value)
        } onCancel: { _ in
            // The run is durable: it continues the next time Mycroft runs. Nothing to undo here.
        }
        return .result(value: answer)
    }

    @MainActor
    private static func ask(_ request: String, progress: Progress) async throws -> String {
        let app = AppModel.shared
        await app.start()
        guard let harness = app.harness else { throw AppModel.StartError.notReady }
        let thread = try await app.startThread(with: request)
        guard let conversation = try await harness.conversation(thread.id) else { return "" }
        progress.totalUnitCount = 100
        // Long-running intents are cancelled when they stop reporting progress; tick while the model works.
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(2))
                progress.completedUnitCount = min(progress.completedUnitCount + 1, 99)
            }
        }
        defer { ticker.cancel() }
        try await conversation.waitForIdle()
        progress.completedUnitCount = 100
        return try await conversation.view().entries.last(where: { $0.kind == .assistant })?.text ?? ""
    }
}

struct MycroftShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskMycroftIntent(), phrases: ["Ask \(.applicationName)"], shortTitle: "Ask Mycroft",
            systemImageName: "sparkle")
    }
}

nonisolated struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
