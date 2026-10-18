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
                extensions: [try await generations.activeExtension(), selfExtension()])
        } catch {
            let state = await generations.state
            guard state.active != state.lastGood else { throw error }
            let failed = try await generations.fallBack()
            notices.append("Generation \(failed) failed to load (\(error.localizedDescription)); running the last good one.")
            return try await Harness.open(
                .sqlite(at: Self.databaseURL), models: models,
                extensions: [try await generations.activeExtension(), selfExtension()])
        }
    }

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

    func send(_ text: String, to thread: ThreadMeta, steer: Bool = false) async throws {
        guard let harness, let conversation = try await harness.conversation(thread.id) else { throw StartError.notReady }
        _ = try await conversation.submit(text, whenBusy: steer ? .steer : .followUp)
        let title = thread.title == ThreadMeta.untitled ? Threads.title(from: text) : nil
        try await harness.update(Threads.document) { list in
            guard let index = list.items.firstIndex(where: { $0.id == thread.id }) else { return }
            list.items[index].updatedAt = .now
            if let title { list.items[index].title = title }
        }
        RunController.shared.runStarted(thread: title ?? thread.title)
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

    /// Whether any recent thread is working. The background run controller polls this.
    func anyBusy() async -> Bool {
        guard let harness else { return false }
        for thread in threads.prefix(12) {
            if let state = try? await harness.conversation(thread.id)?.liveState(), state.run != nil { return true }
        }
        return false
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
