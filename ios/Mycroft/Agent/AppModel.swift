import Foundation
import Observation
import PiDurableKit
import os
import UIKit

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
    /// Every thread, archived ones too, most recently updated first.
    private(set) var threads: [ThreadMeta] = []
    /// Threads made here that the thread list's stream hasn't delivered yet: they are in `threads` at once.
    @ObservationIgnored private var unlisted: [ConversationID: ThreadMeta] = [:]
    /// Threads with a run going, as RunMonitor last saw them.
    private(set) var busyThreads: Set<ConversationID> = []
    private(set) var signIn: SignIn = .unknown
    private(set) var generation = GenerationStore.State()
    private(set) var machines: [Machine] = []
    /// Fluid Speech Mini (Voice/FluidSpeech.swift) is loaded: dictation is transcribed at once. Until then the audio is
    /// kept and transcribed when it is.
    var dictationReady = false
    var notices: [String] = []

    let models = Models(credentials: .keychain(service: "dev.mycroft.credentials"))
    let generations = GenerationStore()
    private(set) var harness: Harness?

    private let log = Logger(subsystem: "dev.mycroft", category: "app")
    private var watchers: [Task<Void, Never>] = []
    private static let databaseURL = URL.documentsDirectory.appending(path: "mycroft.sqlite")
    /// The infinite chat's memory tree (Memory.Files), by conversation.
    private static let memoryURL = URL.documentsDirectory.appending(path: "memory")

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
        Listener.warm(self)
        #if DEBUG
        notices += await DevImport.run(models: models)
        if DevImport.wantsFreshStart {
            do {
                try await freshStart()
                try DevImport.freshStartDone()
            } catch {
                notices.append("The fresh start failed: \(error.localizedDescription)")
            }
        }
        #endif
        do {
            guard let bundled = Bundle.main.url(forResource: "generation-0", withExtension: nil) else {
                throw StartError.missingGeneration0
            }
            try await generations.bootstrap(bundled: bundled)
            if let abandoned = try await generations.beginBoot() {
                notices.append("Generation \(abandoned) kept failing to start, so Mycroft went back to the last good one.")
            }
            // The screen loads while the brain wakes up; it shows the starting state until then.
            let screen = await generations.state.active
            generation = await generations.state
            WebUI.shared.load(generation: screen)
            #if DEBUG
            // UI tests: the brain wakes up well after the screen (as on an iPhone with a big database).
            if CommandLine.arguments.contains("--slow-brain") { try? await Task.sleep(for: .seconds(4)) }
            #endif
            try await ScreenTools.register(on: models)
            let harness = try await openHarness()
            self.harness = harness
            await refreshGeneration()
            if generation.active != screen { WebUI.shared.load(generation: generation.active, recover: false) }
            phase = .ready
            watch(harness)
            if let infinite = await ensureInfinite(harness) {
                Memory.open(infinite, harness: harness, models: models, in: Self.memoryURL)
            }
            await refreshSignIn()
            RunController.shared.attach(self)
            RunMonitor.shared.attach(self)
        } catch {
            log.error("start failed: \(error)")
            phase = .failed(String(describing: error))
        }
    }

    /// A clean Mycroft, for a demo (DevImport): every thread and generation goes (back to the app's own generation 0),
    /// with the screen's saved state, its colours and the journal. The sign-ins and the phone's key (keychain) and the
    /// paired machines stay.
    private func freshStart() async throws {
        let generations = generations
        if let notice = try await Self.freshDatabase(at: Self.databaseURL, beforeSwap: { try await generations.reset() }) {
            notices.append(notice)
        }
        WebBridge.forgetSavedState()
        Journal.clear()
        try? FileManager.default.removeItem(at: Self.memoryURL)
    }

    /// Replaces the database at `database` with one that holds only its paired machines; `beforeSwap` runs once the new
    /// one is ready. Returns a notice when the machines couldn't be kept.
    ///
    /// The new database is made next to the old one and swapped in last. Until then a failure changes nothing; after
    /// it, the next try picks up where this one stopped.
    nonisolated static func freshDatabase(at database: URL, beforeSwap: () async throws -> Void) async throws -> String? {
        let fm = FileManager.default
        let fresh = database.deletingLastPathComponent().appending(path: "mycroft-fresh.sqlite")
        let files = { (database: URL) in ["", "-wal", "-shm"].map { URL(filePath: database.path + $0) } }
        let oldExists = fm.fileExists(atPath: database.path)
        var notice: String?

        // Without the old database, a new one left by an earlier try already holds the machines.
        if oldExists || !fm.fileExists(atPath: fresh.path) {
            for file in files(fresh) where fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
            var machines = MachineList()
            if oldExists {
                do {
                    machines = try await withSession(at: database) { try await $0.document(Machines.document) }
                } catch {
                    // A database that can't be read is a reason for a fresh start, not against one.
                    notice = "The paired machines could not be read, so they go too: \(error.localizedDescription)"
                }
            }
            if !machines.items.isEmpty {
                _ = try await withSession(at: fresh) { session in
                    try await session.update(Machines.document) { [machines] in $0 = machines }
                }
            }
        }

        try await beforeSwap()
        // The old database's main file goes first: if it can't, its threads are still whole for the next try.
        for file in files(database) where fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        for (new, old) in zip(files(fresh), files(database)) where fm.fileExists(atPath: new.path) {
            try fm.moveItem(at: new, to: old)
        }
        return notice
    }

    /// Runs `body` with a session on the database at `url`, closing it whatever happens: one storage takes one
    /// session or harness at a time. A session reads documents without resuming the runs a harness would.
    nonisolated private static func withSession<T: Sendable>(at url: URL, _ body: (Session) async throws -> T) async throws -> T {
        let session = try await Session.open(.sqlite(at: url))
        let result = await Result(catching: { try await body(session) })
        try await session.close()
        return try result.get()
    }

    /// Opens the harness with the active generation; if that generation can't load, falls back once.
    private func openHarness() async throws -> Harness {
        let open = { [self] in
            try await Harness.open(.sqlite(at: Self.databaseURL), models: models, extensions: try await extensions(), settings: Self.settings)
        }
        do {
            return try await open()
        } catch {
            let state = await generations.state
            guard state.active != state.lastGood else { throw error }
            let failed = try await generations.fallBack()
            notices.append("Generation \(failed) failed to load (\(error.localizedDescription)); running the last good one.")
            return try await open()
        }
    }

    /// The agent's extensions: the active generation's, then the native ones. Code mode lets a script call any of
    /// their tools, for the agent and for the screen (ScreenTools); tool search finds the ones kept from the model until
    /// needed (most of Cua Driver's).
    private func extensions() async throws -> [Extension] {
        [
            try await generations.activeExtension(), selfExtension(), HandsTools.makeExtension(), CuaTools.makeExtension(),
            ShowTools.makeExtension(), Memory.makeExtension(), .toolSearch(), .codemode(),
        ]
    }

    /// Tool calls of one step run in parallel, so work on several machines happens at the same time.
    ///
    /// Partial answers are committed every 40 ms (pi-durable's default is 100), so a conversation speaks them sooner.
    nonisolated static let settings = Settings(progress: .init(partialInterval: .milliseconds(40)), toolExecution: .parallel)

    /// A new thread's agent: Sol 6.1 on the ChatGPT subscription, thinking hard.
    nonisolated static let agent = AgentChange(model: Provider.defaultModel, thinkingLevel: .high)

    private func selfExtension() -> Extension {
        SelfTools.makeExtension(store: generations, host: .init(
            preview: { route, snapshot in await UIPreview.run(route: route, snapshot: snapshot) },
            show: { generation in await WebUI.shared.show(generation: generation) },
            rollBack: { [weak self] generation in
                guard let self else { throw StartError.notReady }
                let target = try await self.rollBack(to: generation)
                _ = await WebUI.shared.show(generation: target)
                return target
            },
            activated: { [weak self] _ in await self?.refreshGeneration() },
            screenErrors: { await WebUI.shared.errors }))
    }

    private func watch(_ harness: Harness) {
        watchers.append(Task { [weak self] in
            do {
                for try await list in harness.values(of: Threads.document) {
                    self?.list(list.items)
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
        // A generation that has run for a while without crashing, with a working screen, becomes the one to fall
        // back to.
        watchers.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, WebUI.shared.status == .ready else { return }
            try? await self.generations.markHealthy()
            await self.refreshGeneration()
        })
    }

    /// The user is leaving the app with the screen working: a normal exit, not a crash at start, so the generation is
    /// healthy. (A short visit doesn't reach the 20 s in `watch`, and iOS may end the app in the background; four such
    /// visits must not look like a generation that keeps failing to start.)
    func leaving() async {
        guard phase == .ready, WebUI.shared.status == .ready else { return }
        try? await generations.markHealthy()
        await refreshGeneration()
    }

    private func list(_ items: [ThreadMeta]) {
        let listed = Set(items.map(\.id))
        unlisted = unlisted.filter { !listed.contains($0.key) }
        threads = (items + unlisted.values).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// A thread made here goes into the list at once, before the list's stream has it.
    private func listed(_ meta: ThreadMeta) -> ThreadMeta {
        unlisted[meta.id] = meta
        list(threads.filter { $0.id != meta.id })
        return meta
    }

    func thread(_ id: ConversationID) -> ThreadMeta? {
        threads.first { $0.id == id }
    }

    func refreshGeneration() async {
        generation = await generations.state
    }

    /// Re-activates an earlier generation (the previous one by default), agent and all; the caller puts its screen up.
    func rollBack(to target: Int? = nil) async throws -> Int {
        let state = await generations.state
        let target = target ?? state.previous
        if let harness { try await harness.install(try await generations.extensionFor(generation: target)) }
        try await generations.activate(target)
        await refreshGeneration()
        return target
    }

    /// The screen of a generation failed to load at start: go back to the last good generation, if that's another
    /// one. Returns the generation to load instead.
    func recoverScreen(failed: Int, message: String) async -> Int? {
        let state = await generations.state
        guard state.active == failed, state.lastGood != failed, (try? await rollBack(to: state.lastGood)) != nil else { return nil }
        notices.append("Generation \(failed)'s screen failed to load, so Mycroft went back to generation \(state.lastGood). \(message)")
        return state.lastGood
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

    /// The thread's conversation; throws while Mycroft is starting.
    private func conversation(of thread: ThreadMeta) async throws -> Conversation {
        guard let conversation = try await conversation(thread.id) else { throw StartError.notReady }
        return conversation
    }

    func newThread() async throws -> ThreadMeta {
        guard let harness else { throw StartError.notReady }
        let conversation = try await harness.createConversation(agent: Self.agent)
        let meta = ThreadMeta(id: conversation.id, title: ThreadMeta.untitled, createdAt: .now, updatedAt: .now)
        try await harness.update(Threads.document) { $0.items.append(meta) }
        return listed(meta)
    }

    /// The infinite chat: one thread, made once, that the screen opens from above the list.
    private func ensureInfinite(_ harness: Harness) async -> ConversationID? {
        do {
            if let infinite = try await harness.document(Threads.document).items.first(where: { $0.infinite == true }) { return infinite.id }
            let conversation = try await harness.createConversation(agent: Self.agent)
            var meta = ThreadMeta(id: conversation.id, title: "Mycroft", createdAt: .now, updatedAt: .now)
            meta.infinite = true
            try await harness.update(Threads.document) { [meta] in $0.items.append(meta) }
            _ = listed(meta)
            return meta.id
        } catch {
            log.error("the infinite chat could not be made: \(error)")
            return nil
        }
    }

    /// Creates a thread with its first message: until then a new thread is only a draft on the screen. `voice`: it
    /// starts in a conversation.
    func startThread(with text: String, voice: Bool = false) async throws -> ThreadMeta {
        let meta = try await newThread()
        do {
            if voice { try await setVoice(true, in: meta.id) }
            try await send(text, to: meta)
        } catch {
            // Nothing was said in it: put it away, and the screen keeps the draft.
            try? await edit(meta.id) { $0.archived = true }
            throw error
        }
        return thread(meta.id) ?? meta
    }

    /// Sends `text`. While a run is going, `.followUp` queues it for after the run and `.steer` hands it to the run at
    /// its next step.
    func send(
        _ text: String, to thread: ThreadMeta, whenBusy: Conversation.WhenBusy = .followUp, requestId: String? = nil
    ) async throws {
        let conversation = try await conversation(of: thread)
        _ = try await conversation.submit(text, whenBusy: whenBusy, requestId: requestId)
        let title = thread.title == ThreadMeta.untitled ? Threads.title(from: text) : nil
        try await edit(thread.id) { meta in
            meta.updatedAt = .now
            meta.settledAt = nil
            if let title { meta.title = title }
        }
        var current = thread
        if let title { current.title = title }
        RunMonitor.shared.runSubmitted(current)
    }

    /// Asks the thread's agent to talk (or stops asking): the thread's instructions.
    func setVoice(_ on: Bool, in id: ConversationID) async throws {
        guard let conversation = try await conversation(id) else { return }
        try await conversation.configure(on ? AgentChange(instructions: Instructions.voice) : AgentChange(reset: [.instructions]))
    }

    /// Changes a thread's list metadata.
    func edit(_ id: ConversationID, _ change: @escaping @Sendable (inout ThreadMeta) -> Void) async throws {
        guard let harness else { throw StartError.notReady }
        try await harness.update(Threads.document) { list in
            guard let index = list.items.firstIndex(where: { $0.id == id }) else { return }
            change(&list.items[index])
        }
    }

    /// A new thread with `thread`'s history up to and including `entry` (an answer), named "Fork · <title>" (a
    /// prefix, so it shows in a narrow row).
    func fork(_ thread: ThreadMeta, at entry: EntryID) async throws -> ThreadMeta {
        guard let harness else { throw StartError.notReady }
        let fork = try await conversation(of: thread).fork(at: entry)
        var meta = ThreadMeta(id: fork.id, title: "Fork · \(thread.title)", createdAt: .now, updatedAt: .now)
        meta.parent = thread.id
        try await harness.update(Threads.document) { [meta] in $0.items.append(meta) }
        return listed(meta)
    }

    /// Withdraws a queued message.
    func unqueue(_ thread: ThreadMeta, _ submission: SubmissionID) async throws {
        _ = try await harness?.abortSubmission(submission, in: thread.id)
    }

    /// Hands a queued message to the run now, as a steer.
    func steerNow(_ thread: ThreadMeta, _ submission: SubmissionID) async throws {
        guard let harness, let conversation = try await harness.conversation(thread.id),
            let item = try await conversation.inbox().first(where: { $0.id == submission })
        else { return }
        guard try await harness.abortSubmission(submission, in: thread.id) == .aborted else { return }
        try await send(item.text, to: thread, whenBusy: .steer)
    }

    /// Sends the messages a stop left queued, in order: the first starts a run, the rest follow it.
    func resumeQueue(_ thread: ThreadMeta) async throws {
        guard let harness, let conversation = try await harness.conversation(thread.id) else { return }
        for item in try await conversation.inbox() where item.mode != .write {
            guard try await harness.abortSubmission(item.id, in: thread.id) == .aborted else { continue }
            try await send(item.text, to: thread, whenBusy: .followUp)
        }
    }

    /// RunMonitor saw which threads are running.
    func runsChanged(_ busy: Set<ConversationID>) {
        if busy != busyThreads { busyThreads = busy }
    }

    /// RunMonitor saw a run end.
    func runFinished(_ id: ConversationID, _ outcome: ThreadMeta.Outcome) async {
        try? await edit(id) { meta in
            meta.finishedAt = .now
            meta.outcome = outcome
        }
        if let tree = Memory.tree(id) {
            try? await tree.sync()
            await trim(id)
        }
    }

    /// The infinite chat's model sees its memory, not its transcript (Memory.swift), so Pi never compacts it by tokens:
    /// past `Memory.trim` entries it compacts here, keeping the screen and each request's transcript short.
    private func trim(_ id: ConversationID) async {
        guard let conversation = try? await conversation(id), let view = try? await conversation.view(), view.entries.count > Memory.trim
        else { return }
        do {
            try await conversation.compact()
        } catch {
            log.error("trimming the infinite chat failed: \(error)")
        }
    }

    func isBusy(_ thread: ThreadMeta) async -> Bool {
        ((try? await harness?.conversation(thread.id)?.liveState())?.run) != nil
    }

    /// Stops the run. Queued messages stay queued (paused) until `resumeQueue`.
    func stop(_ thread: ThreadMeta) async throws {
        guard let harness, let conversation = try await harness.conversation(thread.id) else { return }
        if let run = try await conversation.liveState().run {
            _ = try await harness.abortTask(run.taskId)
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
        for thread in threads.filter({ !$0.archived }).prefix(12) {
            guard let conversation = try? await harness.conversation(thread.id) else { continue }
            let live: LiveState
            do {
                live = try await conversation.liveState()
            } catch {
                Journal.note("live_state_failed", ["thread": "\(thread.id.rawValue)", "error": "\(error)"])
                continue
            }
            guard live.run != nil else { continue }
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

    /// Stores a machine that just paired (`MachineList.add`) and returns it as stored.
    @discardableResult
    func addMachine(_ machine: Machine) async throws -> Machine {
        guard let harness else { throw StartError.notReady }
        let list = try await harness.update(Machines.document) { list in _ = list.add(machine) }
        let stored = list.items.first { $0.certSha256 == machine.certSha256 } ?? machine
        await HandsPool.shared.forget(stored)
        return stored
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
    ///
    /// The page is opened by the user from the code screen, inside the app (an in-app Safari page): if Mycroft went to the
    /// background, iOS would suspend it and pi-ai's polling for the approval would be cancelled.
    func signInWithChatGPT() async {
        let interaction = LoginInteraction(
            // PiDurableKit asks to show the verification page as soon as the code exists. Don't: the user needs to
            // see the code first. Wait instead; the sign-in cancels this when it finishes.
            presentSignInPage: { _ in try await Task.sleep(for: .seconds(20 * 60)) },
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
        // A little background time in case the user switches apps while approving.
        let background = UIApplication.shared.beginBackgroundTask(withName: "ChatGPT sign-in")
        defer { UIApplication.shared.endBackgroundTask(background) }
        do {
            try await models.login(to: Provider.codex, interaction: interaction, agentName: "Mycroft")
            signIn = .signedIn
        } catch is CancellationError {
            await refreshSignIn()
        } catch {
            let text = error.localizedDescription
            signIn = .failed(text.localizedCaseInsensitiveContains("cancel")
                ? "Sign-in was interrupted because Mycroft left the screen. Try again and approve the code in the page that opens inside Mycroft."
                : text)
        }
    }

    func signOut() async {
        try? await models.logout(from: Provider.codex)
        signIn = .signedOut
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
