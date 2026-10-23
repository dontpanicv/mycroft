import Observation
import PiDurableKit
import SafariServices
import SwiftUI
import UIKit
import WebKit

/// What Mycroft's web screen can ask of the app, and what the app tells it.
///
/// The page calls `window.webkit.messageHandlers.mycroft.postMessage({ op, args })`, which resolves to the op's
/// result (boot.js wraps it as `call(op, args)`). The app pushes events with `window.mycroft.receive(type, payload)`.
/// Every op and event is listed in agent/generation-0/ui/README.md, which the agent reads before changing its screen.
///
/// A preview bridge (``UIPreview``) answers reads with live data but refuses anything that changes something.
final class WebBridge: NSObject, WKScriptMessageHandlerWithReply {
    enum PageEvent {
        case ready(generation: Int?)
        case failed(generation: Int?, message: String)
        case hot(generation: Int, error: String?)
        case log(level: String, message: String)
    }

    let preview: Bool
    weak var webView: WKWebView?
    var onPageEvent: ((PageEvent) -> Void)?

    private var app: AppModel { AppModel.shared }
    private var stateFeed: Task<Void, Never>?
    private var viewFeeds: [Int: Task<Void, Never>] = [:]
    private var feeds: [String: Task<Void, Never>] = [:]
    private var server: InstallServer?
    private var copiedCommand = ""
    var safari: SFSafariViewController?
    /// The page takes a transcript's new entries alone (`keep`, `append`); an older generation's boot.js wants it whole.
    private var appends = false

    static let uiStateKey = "mycroft.ui.state"

    /// Forgets what the screen saved (where it was, its colours): the next page starts as a new one does.
    static func forgetSavedState() {
        UserDefaults.standard.removeObject(forKey: uiStateKey)
        Appearance.shared.reset()
    }

    init(preview: Bool) {
        self.preview = preview
    }

    // MARK: Calls from the page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else { return (nil, "Malformed call") }
        do {
            return (try await handle(op, Args(body["args"] as? [String: Any] ?? [:])) ?? NSNull(), nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func handle(_ name: String, _ args: Args) async throws -> Any? {
        guard let op = Self.ops[name] else { throw Failure("Unknown op \(name)") }
        if preview {
            switch op.access {
            case .read: break
            case .write: throw Failure("Not available in a preview")
            case .quiet: return nil
            }
        }
        return try await op.run(self, args)
    }

    /// One op of the page. A preview runs only the reads: it shows live data but must change nothing.
    private struct Op {
        enum Access {
            case read
            /// Refused in a preview.
            case write
            /// Does nothing in a preview, without an error: the page's own bookkeeping, and the voice (the app's
            /// one microphone and speaker).
            case quiet
        }

        let access: Access
        let run: @MainActor (WebBridge, Args) async throws -> Any?

        static func read(_ run: @escaping @MainActor (WebBridge, Args) async throws -> Any?) -> Op { Op(access: .read, run: run) }
        static func write(_ run: @escaping @MainActor (WebBridge, Args) async throws -> Any?) -> Op { Op(access: .write, run: run) }
        static func quiet(_ run: @escaping @MainActor (WebBridge, Args) async throws -> Any?) -> Op { Op(access: .quiet, run: run) }
    }

    private static let ops: [String: Op] = pageOps
        .merging(threadOps) { a, _ in a }.merging(machineOps) { a, _ in a }
        .merging(voiceOps) { a, _ in a }.merging(otherOps) { a, _ in a }

    /// The page itself.
    private static let pageOps: [String: Op] = [
        "ui.boot": .read { bridge, args in
            bridge.appends = args.bool("appends") ?? false
            bridge.stopFeeds()
            bridge.startStateFeed()
            // A conversation lives in the app, not the page: a reloaded page (a new generation's boot.js) picks it up.
            if !bridge.preview, bridge.voice.talk.isOn { bridge.followTalk() }
            let saved = bridge.preview ? nil : UserDefaults.standard.string(forKey: uiStateKey)
            return ["state": bridge.stateObject(), "uiState": saved.map { $0 as Any } ?? NSNull(), "preview": bridge.preview]
        },
        "ui.ready": .read { bridge, args in bridge.onPageEvent?(.ready(generation: args.int("generation"))); return nil },
        "ui.failed": .read { bridge, args in
            bridge.onPageEvent?(.failed(generation: args.int("generation"), message: args.string("error") ?? "unknown error"))
            return nil
        },
        "ui.hot": .read { bridge, args in
            bridge.onPageEvent?(.hot(generation: try args.require("generation"), error: args.string("error")))
            return nil
        },
        "ui.log": .read { bridge, args in
            bridge.onPageEvent?(.log(level: args.string("level") ?? "log", message: args.string("message") ?? ""))
            return nil
        },
        "ui.save": .quiet { _, args in UserDefaults.standard.set(args.string("state"), forKey: uiStateKey); return nil },
        "ui.theme": .quiet { bridge, args in bridge.applyTheme(args); return nil },
        "haptic": .quiet { bridge, args in bridge.haptic(args.string("style")); return nil },
        "state.get": .read { bridge, _ in bridge.stateObject() },
    ]

    private static let threadOps: [String: Op] = [
        "thread.create": .write { bridge, args in object(try await bridge.app.startThread(with: try args.require("text"))) },
        "thread.open": .read { bridge, args in
            let id: Int = try args.require("id")
            bridge.openView(id)
            try? await bridge.app.edit(ConversationID(id)) { $0.visitedAt = .now }
            Listener.warm(bridge.app)
            return nil
        },
        "thread.close": .read { bridge, args in
            let id: Int = try args.require("id")
            bridge.viewFeeds.removeValue(forKey: id)?.cancel()
            try? await bridge.app.edit(ConversationID(id)) { $0.visitedAt = .now }
            return nil
        },
        "thread.send": .write { bridge, args in
            let how: Conversation.WhenBusy = args.string("how") == "steer" ? .steer : .followUp
            try await bridge.app.send(try args.require("text"), to: try bridge.thread(args), whenBusy: how)
            return nil
        },
        "thread.stop": .write { bridge, args in try await bridge.app.stop(try bridge.thread(args)); return nil },
        "thread.resume": .write { bridge, args in try await bridge.app.resumeQueue(try bridge.thread(args)); return nil },
        "thread.unqueue": .write { bridge, args in
            try await bridge.app.unqueue(try bridge.thread(args), SubmissionID(try args.require("submission") as Int))
            return nil
        },
        "thread.steerNow": .write { bridge, args in
            try await bridge.app.steerNow(try bridge.thread(args), SubmissionID(try args.require("submission") as Int))
            return nil
        },
        "thread.fork": .write { bridge, args in
            object(try await bridge.app.fork(try bridge.thread(args), at: EntryID(try args.require("entry") as Int)))
        },
        "thread.rename": .write { bridge, args in
            let title = (args.string("title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw Failure("A thread needs a title.") }
            try await bridge.app.edit(try bridge.thread(args).id) { $0.title = title }
            return nil
        },
        "thread.pin": .write { bridge, args in
            let on = args.bool("on") ?? true
            try await bridge.app.edit(try bridge.thread(args).id) { $0.pinned = on ? true : nil }
            return nil
        },
        "thread.settle": .write { bridge, args in
            let on = args.bool("on") ?? true
            try await bridge.app.edit(try bridge.thread(args).id) { meta in
                meta.settledAt = on ? .now : nil
                meta.unsettledAt = on ? nil : .now
                if on { meta.pinned = nil }
            }
            return nil
        },
        "thread.archive": .write { bridge, args in
            let on = args.bool("on") ?? true
            let thread = try bridge.thread(args)
            guard thread.infinite != true else { throw Failure("The infinite chat stays.") }
            try await bridge.app.edit(thread.id) { $0.archived = on }
            return nil
        },
    ]

    /// Machines and pairing.
    private static let machineOps: [String: Op] = [
        "machines.exec": .write { bridge, args in
            let machine = try bridge.machine(try args.require("machine"))
            let timeout = min(60, max(1, Double(args.int("timeoutMs") ?? 15_000) / 1000))
            let result = try await HandsTools.run(try args.require("command"), cwd: args.string("cwd"), on: machine, timeout: timeout)
            return ["exitCode": result.exitCode.map { $0 as Any } ?? NSNull(), "output": result.output]
        },
        "machines.check": .read { bridge, _ in await bridge.checkMachines() },
        "machines.forget": .write { bridge, args in
            try await bridge.app.removeMachine(try bridge.machine(try args.require("name")))
            return nil
        },
        "pairing.start": .write { bridge, args in await bridge.startPairing(prefer: args.string("prefer")); return nil },
        "pairing.choose": .write { bridge, args in bridge.server?.chosen = args.string("ip"); return nil },
        "pairing.stop": .read { bridge, _ in bridge.stopPairing(); return nil },
    ]

    /// Dictation into a composer (Voice/Listener.swift) and conversation mode (Voice/VoiceChat.swift).
    private static let voiceOps: [String: Op] = [
        "listen.start": .write { bridge, args in
            bridge.endTalk()
            await bridge.voice.listener.start(try args.require("owner"), prefix: args.string("prefix") ?? "")
            bridge.followListener()
            return nil
        },
        "listen.stop": .quiet { bridge, _ in ["text": await bridge.voice.listener.stop()] },
        "listen.cancel": .quiet { bridge, _ in bridge.voice.listener.cancel(); return nil },
        "listen.clear": .quiet { bridge, _ in bridge.voice.listener.clear(); return nil },
        "listen.close": .quiet { bridge, _ in
            // A conversation keeps the listener when a composer goes away.
            if !bridge.voice.talk.isOn { bridge.voice.listener.shutDown() }
            return nil
        },
        "talk.start": .write { bridge, args in
            let talk = bridge.voice.talk
            await talk.start(thread: args.int("id"))
            bridge.followTalk()
            if !talk.isOn, let error = talk.error { throw Failure(error) }
            return nil
        },
        "talk.end": .quiet { bridge, _ in bridge.endTalk(); return nil },
        "talk.tap": .quiet { bridge, _ in bridge.voice.talk.tap(); return nil },
        "talk.mute": .quiet { bridge, args in bridge.voice.talk.mute(args.bool("on") ?? true); return nil },
        "voice.choose": .write { bridge, args in
            guard let voice = args.string("voice"), Speaker.voices.contains(where: { $0.id == voice }) else {
                throw Failure("Unknown voice")
            }
            if bridge.voice.talk.isOn {
                Speaker.shared.voice = voice
            } else {
                try await Speaker.shared.sample(voice)
            }
            return nil
        },
    ]

    /// Sign-in, the agent's tools and generations, and the rest.
    private static let otherOps: [String: Op] = [
        "signin.start": .write { bridge, _ in
            Task { await bridge.app.signInWithChatGPT() }
            return nil
        },
        "signin.open": .write { bridge, args in
            if let code = args.string("code") { UIPasteboard.general.string = code }
            if let url = URL(string: try args.require("url")) { bridge.present(url) }
            return nil
        },
        "signin.signOut": .write { bridge, _ in await bridge.app.signOut(); return nil },
        // The agent's tools (Agent/ScreenTools.swift)
        "tools.list": .read { bridge, _ in try await ScreenTools.shared.list(try bridge.ready()) },
        "tools.call": .write { bridge, args in
            let calls: [ScreenTools.Call]
            if let many = args.values["calls"] as? [[String: Any]] {
                calls = try many.map { ScreenTools.Call(name: try Args($0).require("name"), arguments: try json($0["arguments"])) }
            } else {
                calls = [ScreenTools.Call(name: try args.require("name"), arguments: try json(args.values["arguments"]))]
            }
            let results = try await ScreenTools.shared.call(calls, harness: try bridge.ready())
            return args.values["calls"] == nil ? results.first : results
        },
        "generation.rollback": .write { bridge, args in
            let target = try await bridge.app.rollBack(to: args.int("generation"))
            Task { _ = await WebUI.shared.show(generation: target) }
            return target
        },
        "clipboard.copy": .write { _, args in UIPasteboard.general.string = args.string("text") ?? ""; return nil },
        "open.url": .quiet { bridge, args in
            if let url = URL(string: try args.require("url")) { bridge.present(url) }
            return nil
        },
        "notices.thirdParty": .read { _, _ in thirdPartyNotices },
    ]

    /// The app's one voice session; never a preview's.
    private var voice: VoiceSession { VoiceSession.shared }

    private func machine(_ name: String) throws -> Machine {
        guard let machine = MachineList(items: app.machines).named(name) else { throw Failure("No machine named \(name)") }
        return machine
    }

    private func ready() throws -> Harness {
        guard let harness = app.harness else { throw Failure("Mycroft is still starting") }
        return harness
    }

    private func thread(_ args: Args) throws -> ThreadMeta {
        let id: Int = try args.require("id")
        guard let thread = app.thread(ConversationID(id)) else { throw Failure("No thread \(id)") }
        return thread
    }

    // MARK: Events to the page

    func send(_ type: String, _ payload: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed]),
            let json = String(data: data, encoding: .utf8)
        else { return }
        send(type, json: json)
    }

    func send(_ type: String, json: String) {
        webView?.callAsyncJavaScript(
            "window.mycroft && window.mycroft.receive(type, JSON.parse(json))", arguments: ["type": type, "json": json],
            in: nil, in: .page, completionHandler: nil)
    }

    /// Everything the screen shows outside a thread. Sent again whenever any of it changes.
    func stateObject() -> [String: Any] {
        let signIn: [String: Any] = switch app.signIn {
        case .unknown: ["state": "unknown"]
        case .signedOut: ["state": "signedOut"]
        case .signedIn: ["state": "signedIn"]
        case .waitingForCode(let code, let url): ["state": "waiting", "code": code, "url": url.absoluteString]
        case .failed(let message): ["state": "failed", "message": message]
        }
        let phase: [String: Any] = switch app.phase {
        case .starting: ["phase": "starting"]
        case .ready: ["phase": "ready"]
        case .failed(let message): ["phase": "failed", "failure": message]
        }
        let voice: [String: Any] = [
            "bundled": Speaker.isBundled, "ready": Speaker.shared.ready, "voice": Speaker.shared.voice,
            "voices": Speaker.voices.map { ["id": $0.id, "name": $0.name, "accent": $0.accent] },
        ]
        return phase.merging([
            "generation": Self.object(app.generation) ?? NSNull(),
            "threads": Self.object(app.threads.filter { !$0.archived && $0.infinite != true }) ?? [],
            "infinite": app.threads.first(where: { $0.infinite == true }).flatMap { Self.object($0) } ?? NSNull(),
            "archived": Self.object(app.threads.filter(\.archived)) ?? [],
            "busy": app.busyThreads.map(\.rawValue).sorted(),
            "signIn": signIn,
            "dictation": ["bundled": FluidSpeech.isBundled, "ready": app.dictationReady],
            "voice": voice,
            "machines": Self.object(app.machines) ?? [],
            "notices": app.notices,
            "model": Provider.defaultModel.modelId,
            "screenErrors": WebUI.shared.errors,
        ]) { a, _ in a }
    }

    private func startStateFeed() {
        stateFeed?.cancel()
        stateFeed = Task { [weak self] in
            let changes = Observations { [weak self] in self.map { Self.json($0.stateObject()) } ?? "" }
            for await json in changes {
                guard let self, !Task.isCancelled else { return }
                self.send("state", json: json)
                if self.app.signIn == .signedIn, let safari = self.safari {
                    safari.dismiss(animated: true)
                    self.safari = nil
                }
            }
        }
    }

    /// Streams one conversation to the page: the transcript when it changes, the live state on every commit. The
    /// transcript goes whole once, then as the entries after those the page already has: a long desktop-control run
    /// adds a screenshot at almost every step.
    private func openView(_ id: Int) {
        viewFeeds[id]?.cancel()
        viewFeeds[id] = Task { [weak self] in
            guard let conversation = await self?.conversation(id), !Task.isCancelled else { return }
            var shown: [EntryID]?
            do {
                for try await view in conversation.views() {
                    guard let self, !Task.isCancelled else { return }
                    let ids = view.entries.map(\.id)
                    var payload: [String: Any] = [
                        "thread": id, "busy": view.isBusy,
                        "queued": view.inbox.filter { $0.mode != .write }.map { ["id": $0.id.rawValue, "mode": $0.mode.rawValue, "text": $0.text] },
                        "model": view.agent.model?.modelId ?? NSNull(),
                        "live": view.documents["pi.live"].flatMap(Self.object) ?? NSNull(),
                    ]
                    if ids != shown {
                        let keep = self.appends ? zip(shown ?? [], ids).prefix { $0 == $1 }.count : 0
                        if keep > 0 {
                            payload["keep"] = keep
                            payload["append"] = Self.slim(Self.object(Array(view.entries.dropFirst(keep))) ?? [])
                        } else {
                            payload["entries"] = Self.slim(Self.object(view.entries) ?? [])
                        }
                        shown = ids
                    }
                    self.send("view", payload)
                }
            } catch {
                self?.send("view", ["thread": id, "error": error.localizedDescription])
            }
        }
    }

    /// Thread `id`'s conversation, or nil after telling the page why there is none. The screen loads while the brain wakes
    /// up, and reopens the thread that was open at once: this waits for the brain, or a thread that exists would be
    /// reported missing.
    private func conversation(_ id: Int) async -> Conversation? {
        await app.start()
        do {
            if let conversation = try await app.conversation(ConversationID(id)) { return conversation }
            send("view", ["thread": id, "error": app.harness == nil ? "Mycroft could not start." : "This thread no longer exists."])
        } catch {
            send("view", ["thread": id, "error": error.localizedDescription])
        }
        return nil
    }

    /// Polls a native object while the page needs it and sends what changed. For the voice: its clocks (`elapsed`) move
    /// with time, not with anything observable.
    private func feed(_ type: String, every interval: Duration = .milliseconds(100), _ read: @escaping () -> [String: Any]) {
        feeds[type]?.cancel()
        feeds[type] = Task { [weak self] in
            var last = ""
            while !Task.isCancelled {
                let json = Self.json(read())
                if json != last {
                    last = json
                    self?.send(type, json: json)
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Sends what `read` returns whenever the observable state it reads changes.
    private func observe(_ type: String, _ read: @escaping () -> [String: Any]) {
        feeds[type]?.cancel()
        feeds[type] = Task { [weak self] in
            for await json in Observations({ Self.json(read()) }) {
                guard let self, !Task.isCancelled else { return }
                self.send(type, json: json)
            }
        }
    }

    private func stopFeeds() {
        viewFeeds.values.forEach { $0.cancel() }
        viewFeeds = [:]
        stopPairing()
        if !preview, !voice.talk.isOn { voice.listener.shutDown() }
    }

    /// The page went away for good.
    func tearDown() {
        stateFeed?.cancel()
        endTalk()
        stopFeeds()
    }

    // MARK: Voice, pairing

    /// The `talk` events while a conversation is on.
    private func followTalk() {
        let talk = voice.talk
        guard talk.isOn || talk.error != nil else { return }
        feed("talk", every: .milliseconds(80)) { talk.snapshot() }
    }

    /// Ends the conversation, if one is on, and tells the page.
    private func endTalk() {
        guard !preview, voice.talk.isOn else { return }
        let talk = voice.talk
        talk.end()
        feeds.removeValue(forKey: "talk")?.cancel()
        send("talk", talk.snapshot())
    }

    /// The `listen` events while the listener is in use; they stop with the page.
    private func followListener() {
        guard feeds["listen"] == nil else { return }
        let listener = voice.listener
        feed("listen", every: .milliseconds(80)) { listener.snapshot() }
    }

    private func startPairing(prefer: String?) async {
        stopPairing()
        // Ask iOS for local-network access first: until it is granted, the computer's download is refused.
        let network = await LocalNetworkPermission.request(wait: 4)
        let server = InstallServer()
        self.server = server
        server.start(prefer: prefer) { machine in try await AppModel.shared.addMachine(machine) }
        observe("pairing") { [weak self] in
            var state: [String: Any] = [
                "command": server.command, "pinned": server.pinnedCommand, "localNetwork": network == .denied ? "denied" : "ok",
                "addresses": server.addresses.map { ["network": $0.network, "ip": $0.ip] }, "chosen": server.address?.ip ?? NSNull(),
            ]
            switch server.state {
            case .starting: state["state"] = "starting"
            case .waiting: state["state"] = "waiting"
            case .paired(let machine): state["state"] = "paired"; state["machine"] = Self.object(machine)
            case .failed(let message): state["state"] = "failed"; state["message"] = message
            }
            // The command goes straight to the clipboard: with Universal Clipboard it's ready to paste on the Mac.
            if let self, !server.command.isEmpty, self.copiedCommand != server.command {
                UIPasteboard.general.string = server.command
                self.copiedCommand = server.command
            }
            state["copied"] = self?.copiedCommand == server.command && !server.command.isEmpty
            return state
        }
    }

    private func stopPairing() {
        feeds.removeValue(forKey: "pairing")?.cancel()
        server?.stop()
        server = nil
    }

    /// Connects to every paired machine: "online" or why it can't be reached.
    private func checkMachines() async -> [String: String] {
        var status: [String: String] = [:]
        await withTaskGroup(of: (String, String).self) { group in
            for machine in app.machines {
                group.addTask {
                    do {
                        _ = try await HandsPool.shared.connection(to: machine)
                        return (machine.name, "online")
                    } catch {
                        return (machine.name, error.localizedDescription)
                    }
                }
            }
            for await (name, result) in group { status[name] = result }
        }
        return status
    }
}
