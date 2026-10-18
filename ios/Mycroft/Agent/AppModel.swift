import Foundation
import Observation
import PiDurableKit
import os

/// The app's brain: one Pi Durable harness over one SQLite file, the agent's generations, and the thread list.
@Observable
final class AppModel {
    /// One brain per process: the app's UI and App Intents share it.
    static let shared = AppModel()

    enum Phase: Equatable {
        case starting
        case ready
        case failed(String)
    }

    enum SignIn: Equatable {
        case unknown, signedOut, signedIn
        case waitingForCode(code: String, url: URL)
        case failed(String)
    }

    private(set) var phase: Phase = .starting
    private(set) var threads: [ThreadMeta] = []
    private(set) var signIn: SignIn = .unknown
    private(set) var generation = GenerationStore.State()
    private(set) var hasJevKey = Keychain.read(Secret.jev) != nil
    private(set) var machines: [Machine] = []
    var notices: [String] = []

    let models = Models(credentials: .keychain(service: "dev.mycroft.credentials"))
    let generations = GenerationStore()
    private(set) var harness: Harness?

    private let log = Logger(subsystem: "dev.mycroft", category: "app")
    private var watchers: [Task<Void, Never>] = []
    private static let databaseURL = URL.documentsDirectory.appending(path: "mycroft.sqlite")

    // MARK: Start

    func start() async {
        if let starting { return await starting.value }
        let task = Task { await boot() }
        starting = task
        await task.value
    }

    @ObservationIgnored private var starting: Task<Void, Never>?

    private func boot() async {
        protectDocuments()
        notices += await DevImport.run(models: models)
        hasJevKey = Keychain.read(Secret.jev) != nil
        hasOpenAIKey = Keychain.read(Secret.openAI) != nil
        do {
            guard let bundled = Bundle.main.url(forResource: "generation-0", withExtension: nil) else {
                throw StartError.missingGeneration0
            }
            try await generations.bootstrap(bundled: bundled)
            if let abandoned = try await generations.beginBoot() {
                notices.append("Generation \(abandoned) kept failing to start, so Mycroft went back to the last good one.")
            }
            let harness = try await openHarness()
            self.harness = harness
            generation = await generations.state
            phase = .ready
            watch(harness)
            await refreshSignIn()
            RunController.shared.attach(self)
            RunMonitor.shared.attach(self)
        } catch {
            log.error("start failed: \(error)")
            phase = .failed(String(describing: error))
        }
    }

    /// Opens the harness with the active generation; if that generation can't load, falls back once.
    private func openHarness() async throws -> Harness {
        do {
            return try await Harness.open(
                .sqlite(at: Self.databaseURL), models: models,
                extensions: [try await generations.activeExtension(), selfExtension(), HandsTools.makeExtension()],
                settings: Self.settings)
        } catch {
            let state = await generations.state
            guard state.active != state.lastGood else { throw error }
            let failed = try await generations.fallBack()
            notices.append("Generation \(failed) failed to load (\(error.localizedDescription)); running the last good one.")
            return try await Harness.open(
                .sqlite(at: Self.databaseURL), models: models,
                extensions: [try await generations.activeExtension(), selfExtension(), HandsTools.makeExtension()],
                settings: Self.settings)
        }
    }

    /// Tool calls of one step run in parallel, so work on several machines happens at the same time.
    nonisolated static let settings = Settings(toolExecution: .parallel)

    private func selfExtension() -> Extension {
        SelfTools.makeExtension(store: generations) { [weak self] _ in
            await self?.refreshGeneration()
        }
    }

    private func watch(_ harness: Harness) {
        watchers.append(Task { [weak self] in
            do {
                for try await list in harness.values(of: Threads.document) {
                    self?.threads = list.items.filter { !$0.archived }.sorted { $0.updatedAt > $1.updatedAt }
                }
            } catch {
                self?.log.error("thread list stream ended: \(error)")
            }
        })
        watchers.append(Task { [weak self] in
            do {
                for try await list in harness.values(of: Machines.document) {
                    self?.machines = list.items.sorted { $0.pairedAt > $1.pairedAt }
                }
            } catch {
                self?.log.error("machine list stream ended: \(error)")
            }
        })
        // A generation that has run for a while without crashing becomes the one to fall back to.
        watchers.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self else { return }
            try? await self.generations.markHealthy()
            await self.refreshGeneration()
        })
    }

    func refreshGeneration() async {
        generation = await generations.state
    }

    /// Documents keep working while the phone is locked: the database and agent code are readable after first unlock.
    private func protectDocuments() {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: URL.documentsDirectory.path)
    }

    // MARK: Threads

    func conversation(_ id: ConversationID) async throws -> Conversation? {
        try await harness?.conversation(id)
    }

    func newThread() async throws -> ThreadMeta {
        guard let harness else { throw StartError.notReady }
        let conversation = try await harness.createConversation(
            agent: AgentChange(model: Provider.defaultModel, thinkingLevel: .medium))
        let meta = ThreadMeta(id: conversation.id, title: ThreadMeta.untitled, createdAt: .now, updatedAt: .now)
        try await harness.update(Threads.document) { $0.items.append(meta) }
        return meta
    }

    func send(_ text: String, to thread: ThreadMeta, steer: Bool = false, requestId: String? = nil) async throws {
        guard let harness, let conversation = try await harness.conversation(thread.id) else { throw StartError.notReady }
        _ = try await conversation.submit(text, whenBusy: steer ? .steer : .followUp, requestId: requestId)
        let title = thread.title == ThreadMeta.untitled ? Threads.title(from: text) : nil
        try await harness.update(Threads.document) { list in
            guard let index = list.items.firstIndex(where: { $0.id == thread.id }) else { return }
            list.items[index].updatedAt = .now
            if let title { list.items[index].title = title }
        }
        RunController.shared.runStarted(thread: title ?? thread.title)
        RunMonitor.shared.kick()
    }

    /// The thread live voice works in, created on first use.
    func voiceThread() async throws -> ThreadMeta {
        if let existing = threads.first(where: { $0.title == Self.voiceTitle }) { return existing }
        var thread = try await newThread()
        thread.title = Self.voiceTitle
        let id = thread.id
        try await harness?.update(Threads.document) { list in
            if let index = list.items.firstIndex(where: { $0.id == id }) { list.items[index].title = Self.voiceTitle }
        }
        return thread
    }

    nonisolated static let voiceTitle = "Voice"

    func isBusy(_ thread: ThreadMeta) async -> Bool {
        ((try? await harness?.conversation(thread.id)?.liveState())?.run) != nil
    }

    /// What the newest turn did so far, as activity headlines, oldest first.
    func recentSteps(_ thread: ThreadMeta) async -> [String] {
        guard let conversation = try? await harness?.conversation(thread.id),
            let entries = try? await conversation.entries(limit: 24).items
        else { return [] }
        var calls: [ToolCall] = []
        for entry in entries {
            if entry.kind == .user { break }
            for case .toolCall(let call) in entry.assistantMessage?.content ?? [] { calls.insert(call, at: 0) }
        }
        return calls.map { ActivitySummary.describe(tool: $0.name, arguments: $0.arguments).headline }
    }

    func lastAnswer(_ thread: ThreadMeta) async -> String? {
        let entries = (try? await harness?.conversation(thread.id)?.entries(limit: 6).items) ?? []
        return entries.first(where: { $0.kind == .assistant })?.assistantMessage?.content.compactMap(\.text).joined(separator: "\n")
    }

    func stop(_ thread: ThreadMeta) async throws {
        try await harness?.conversation(thread.id)?.abort()
    }

    func archive(_ thread: ThreadMeta) async throws {
        try await harness?.update(Threads.document) { list in
            guard let index = list.items.firstIndex(where: { $0.id == thread.id }) else { return }
            list.items[index].archived = true
        }
    }

    /// A thread that is working right now, with the tool calls of its newest turns.
    struct RunSnapshot {
        let thread: ThreadMeta
        let live: LiveState
        let calls: [ToolCall]
    }

    /// The busy threads among the recent ones. The run monitor polls this.
    func busySnapshots() async -> [RunSnapshot] {
        guard let harness else { return [] }
        var snapshots: [RunSnapshot] = []
        for thread in threads.prefix(12) {
            guard let conversation = try? await harness.conversation(thread.id),
                let live = try? await conversation.liveState(), live.run != nil
            else { continue }
            let recent = (try? await conversation.entries(limit: 6).items) ?? []
            let messages = recent.reversed().compactMap(\.assistantMessage) + [live.generation?.message].compactMap { $0 }
            let calls = messages.flatMap { message in
                message.content.compactMap { block -> ToolCall? in
                    if case .toolCall(let call) = block { call } else { nil }
                }
            }
            snapshots.append(RunSnapshot(thread: thread, live: live, calls: calls))
        }
        return snapshots
    }

    /// How the newest answer of a thread ended: stop, error, aborted…
    func lastStopReason(_ thread: ConversationID) async -> StopReason? {
        let entries = (try? await harness?.conversation(thread)?.entries(limit: 4).items) ?? []
        return entries.first(where: { $0.kind == .assistant })?.assistantMessage?.stopReason
    }

    // MARK: Machines

    /// Stores a machine that just paired; a machine with the same name is replaced.
    func addMachine(_ machine: Machine) async throws {
        guard let harness else { throw StartError.notReady }
        try await harness.update(Machines.document) { list in
            list.items.removeAll { $0.name.caseInsensitiveCompare(machine.name) == .orderedSame }
            list.items.append(machine)
        }
        await HandsPool.shared.forget(machine)
    }

    func removeMachine(_ machine: Machine) async throws {
        try await harness?.update(Machines.document) { list in list.items.removeAll { $0.name == machine.name } }
        await HandsPool.shared.forget(machine)
    }

    // MARK: Sign-in

    func refreshSignIn() async {
        let configured = (try? await models.isConfigured(Provider.codex)) ?? false
        signIn = configured ? .signedIn : .signedOut
    }

    /// ChatGPT sign-in with a device code: show the code, the user approves it at auth.openai.com.
    func signInWithChatGPT(open: @escaping @Sendable (URL) -> Void) async {
        let interaction = LoginInteraction(
            presentSignInPage: { url in open(url) },
            prompt: { prompt in
                if case .select(_, let options) = prompt, let device = options.first(where: { $0.id == "device_code" }) {
                    return device.id
                }
                return try await prompt.defaultAnswer()
            },
            notify: { [weak self] event in
                guard case .deviceCode(let code, let url) = event else { return }
                Task { @MainActor in self?.signIn = .waitingForCode(code: code, url: url) }
            })
        do {
            try await models.login(to: Provider.codex, interaction: interaction, agentName: "Mycroft")
            signIn = .signedIn
        } catch is CancellationError {
            await refreshSignIn()
        } catch {
            signIn = .failed(error.localizedDescription)
        }
    }

    func signOut() async {
        try? await models.logout(from: Provider.codex)
        signIn = .signedOut
    }

    // MARK: Keys

    private(set) var hasOpenAIKey = Keychain.read(Secret.openAI) != nil

    func saveOpenAIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Keychain.delete(Secret.openAI) } else { try Keychain.write(trimmed, for: Secret.openAI) }
        hasOpenAIKey = !trimmed.isEmpty
    }

    // MARK: Jev

    func saveJevKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(Secret.jev)
        } else {
            try Keychain.write(trimmed, for: Secret.jev)
        }
        hasJevKey = !trimmed.isEmpty
    }

    enum StartError: LocalizedError {
        case missingGeneration0, notReady
        var errorDescription: String? {
            switch self {
            case .missingGeneration0: "The app bundle has no generation-0 agent."
            case .notReady: "Mycroft is still starting."
            }
        }
    }
}
