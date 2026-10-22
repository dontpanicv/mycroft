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
    private let listener = Listener()
    private lazy var talk = VoiceChat(listener: listener)
    private var server: InstallServer?
    private var copiedCommand = ""
    private var safari: SFSafariViewController?
    /// Threads created by this page that the thread list may not show yet.
    private var created: [Int: ThreadMeta] = [:]

    static let uiStateKey = "mycroft.ui.state"

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

    private func handle(_ op: String, _ args: Args) async throws -> Any? {
        switch op {
        // The page itself
        case "ui.boot":
            stopFeeds()
            startStateFeed()
            // A conversation lives in the app, not the page: a reloaded page (a new generation's boot.js) picks it up.
            if talk.isOn { followTalk() }
            let saved = preview ? nil : UserDefaults.standard.string(forKey: Self.uiStateKey)
            return ["state": stateObject(), "uiState": saved ?? NSNull(), "preview": preview]
        case "ui.ready":
            onPageEvent?(.ready(generation: args.int("generation")))
        case "ui.failed":
            onPageEvent?(.failed(generation: args.int("generation"), message: args.string("error") ?? "unknown error"))
        case "ui.hot":
            onPageEvent?(.hot(generation: try args.require("generation"), error: args.string("error")))
        case "ui.log":
            onPageEvent?(.log(level: args.string("level") ?? "log", message: args.string("message") ?? ""))
        case "ui.save":
            if !preview { UserDefaults.standard.set(args.string("state"), forKey: Self.uiStateKey) }
        case "ui.theme":
            if !preview { applyTheme(args) }
        case "haptic":
            if !preview { haptic(args.string("style")) }

        // Threads
        case "state.get":
            return stateObject()
        case "thread.create":
            try writable()
            let thread = try await app.startThread(with: try args.require("text"))
            created[thread.id.rawValue] = thread
            return Self.object(thread)
        case "thread.open":
            let id: Int = try args.require("id")
            openView(id)
            try? await app.edit(ConversationID(id)) { $0.visitedAt = .now }
            Listener.warm(app)
        case "thread.close":
            let id: Int = try args.require("id")
            viewFeeds.removeValue(forKey: id)?.cancel()
            try? await app.edit(ConversationID(id)) { $0.visitedAt = .now }
        case "thread.send":
            try writable()
            let how: Conversation.WhenBusy = args.string("how") == "steer" ? .steer : .followUp
            try await app.send(try args.require("text"), to: try thread(args), whenBusy: how)
        case "thread.stop":
            try writable()
            try await app.stop(try thread(args))
        case "thread.resume":
            try writable()
            try await app.resumeQueue(try thread(args))
        case "thread.unqueue":
            try writable()
            try await app.unqueue(try thread(args), SubmissionID(try args.require("submission") as Int))
        case "thread.steerNow":
            try writable()
            try await app.steerNow(try thread(args), SubmissionID(try args.require("submission") as Int))
        case "thread.fork":
            try writable()
            let fork = try await app.fork(try thread(args), at: EntryID(try args.require("entry") as Int))
            created[fork.id.rawValue] = fork
            return Self.object(fork)
        case "thread.rename":
            try writable()
            let title = (args.string("title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw BridgeError("A thread needs a title.") }
            try await app.edit(try thread(args).id) { $0.title = title }
        case "thread.pin":
            try writable()
            let on = args.bool("on") ?? true
            try await app.edit(try thread(args).id) { $0.pinned = on ? true : nil }
        case "thread.settle":
            try writable()
            let on = args.bool("on") ?? true
            try await app.edit(try thread(args).id) { meta in
                meta.settledAt = on ? .now : nil
                meta.unsettledAt = on ? nil : .now
                if on { meta.pinned = nil }
            }
        case "thread.archive":
            try writable()
            let on = args.bool("on") ?? true
            try await app.edit(try thread(args).id) { $0.archived = on }

        // Sign-in and keys
        case "signin.start":
            try writable()
            Task { await app.signInWithChatGPT() }
        case "signin.open":
            try writable()
            if let code = args.string("code") { UIPasteboard.general.string = code }
            if let url = URL(string: try args.require("url")) { present(url) }
        case "signin.signOut":
            try writable()
            await app.signOut()

        // Machines
        case "machines.exec":
            try writable()
            let name: String = try args.require("machine")
            guard let machine = app.machines.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw BridgeError("No machine named \(name)")
            }
            let timeout = min(60, max(1, Double(args.int("timeoutMs") ?? 15_000) / 1000))
            let result = try await HandsTools.run(try args.require("command"), cwd: args.string("cwd"), on: machine, timeout: timeout)
            return ["exitCode": result.exitCode.map { $0 as Any } ?? NSNull(), "output": result.output]
        case "machines.check":
            return await checkMachines()
        case "machines.forget":
            try writable()
            guard let machine = app.machines.first(where: { $0.name == args.string("name") }) else { throw BridgeError("No such machine") }
            try await app.removeMachine(machine)
        case "pairing.start":
            try writable()
            await startPairing(prefer: args.string("prefer"))
        case "pairing.choose":
            server?.chosen = args.string("ip")
        case "pairing.stop":
            stopPairing()

        // The agent's tools (Agent/ScreenTools.swift)
        case "tools.list":
            return try await ScreenTools.shared.list(try ready())
        case "tools.call":
            try writable()
            let calls: [ScreenTools.Call]
            if let many = args.values["calls"] as? [[String: Any]] {
                calls = try many.map { ScreenTools.Call(name: try Args($0).require("name"), arguments: try Self.json($0["arguments"])) }
            } else {
                calls = [ScreenTools.Call(name: try args.require("name"), arguments: try Self.json(args.values["arguments"]))]
            }
            let results = try await ScreenTools.shared.call(calls, harness: try ready())
            return args.values["calls"] == nil ? results.first : results

        // Dictation into a composer (Voice/Listener.swift)
        case "listen.start":
            try writable()
            endTalk()
            await listener.start(try args.require("owner"), prefix: args.string("prefix") ?? "")
            followListener()
        case "listen.stop":
            return ["text": await listener.stop()]
        case "listen.cancel":
            listener.cancel()
        case "listen.clear":
            listener.clear()
        case "listen.close":
            // A conversation keeps the listener when a composer goes away.
            if !talk.isOn { listener.shutDown() }

        // Conversation mode (Voice/VoiceChat.swift)
        case "talk.start":
            try writable()
            await talk.start(thread: args.int("id"))
            followTalk()
            if !talk.isOn, let error = talk.error { throw BridgeError(error) }
        case "talk.end":
            endTalk()
        case "talk.tap":
            talk.tap()
        case "talk.mute":
            talk.mute(args.bool("on") ?? true)
        case "voice.choose":
            try writable()
            guard let voice = args.string("voice"), Speaker.voices.contains(where: { $0.id == voice }) else {
                throw BridgeError("Unknown voice")
            }
            if talk.isOn {
                Speaker.shared.voice = voice
            } else {
                try await Speaker.shared.sample(voice)
            }

        // Self
        case "generation.rollback":
            try writable()
            let target = try await app.rollBack(to: args.int("generation"))
            Task { _ = await WebUI.shared.show(generation: target) }
            return target

        // Misc
        case "clipboard.copy":
            try writable()
            UIPasteboard.general.string = args.string("text") ?? ""
        case "open.url":
            if !preview, let url = URL(string: try args.require("url")) { present(url) }
        case "notices.thirdParty":
            return Self.notices
        default:
            throw BridgeError("Unknown op \(op)")
        }
        return nil
    }

    private func writable() throws {
        if preview { throw BridgeError("Not available in a preview") }
    }

    private func ready() throws -> Harness {
        guard let harness = app.harness else { throw BridgeError("Mycroft is still starting") }
        return harness
    }

    private func thread(_ args: Args) throws -> ThreadMeta {
        let id: Int = try args.require("id")
        if let thread = (app.threads + app.archivedThreads).first(where: { $0.id.rawValue == id }) ?? created[id] {
            return thread
        }
        throw BridgeError("No thread \(id)")
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
            "threads": Self.object(app.threads) ?? [],
            "archived": Self.object(app.archivedThreads) ?? [],
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

    /// Streams one conversation to the page: the transcript when it changes, the live state on every commit.
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
                        payload["entries"] = Self.slim(Self.object(view.entries) ?? [])
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

    /// Polls a native object while the page needs it and sends what changed.
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

    private func stopFeeds() {
        viewFeeds.values.forEach { $0.cancel() }
        viewFeeds = [:]
        stopPairing()
        if !talk.isOn { listener.shutDown() }
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
        guard talk.isOn || talk.error != nil else { return }
        feed("talk", every: .milliseconds(80)) { [talk] in talk.snapshot() }
    }

    /// Ends the conversation, if one is on, and tells the page.
    private func endTalk() {
        guard talk.isOn else { return }
        talk.end()
        feeds.removeValue(forKey: "talk")?.cancel()
        send("talk", talk.snapshot())
    }

    /// The `listen` events while the listener is in use; they stop with the page.
    private func followListener() {
        guard feeds["listen"] == nil else { return }
        feed("listen", every: .milliseconds(80)) { [listener] in listener.snapshot() }
    }

    private func startPairing(prefer: String?) async {
        stopPairing()
        // Ask iOS for local-network access first: until it is granted, the computer's download is refused.
        let network = await LocalNetworkPermission.request(wait: 4)
        let server = InstallServer()
        self.server = server
        server.start(prefer: prefer) { machine in try await AppModel.shared.addMachine(machine) }
        feed("pairing", every: .milliseconds(250)) { [weak self] in
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

    // MARK: Native bits

    /// The page's colours, for what is drawn natively: the Live Activity, the recovery screen, Safari.
    private func applyTheme(_ args: Args) {
        func hex(_ key: String) -> String? {
            args.string(key).flatMap { Color.components(hex: $0) == nil ? nil : $0 }
        }
        Appearance.shared.apply(.init(accent: hex("accent"), accentSoft: hex("accentSoft"), canvas: hex("canvas"),
                                      raised: hex("raised"), ink: hex("ink"), inkMuted: hex("inkMuted"),
                                      success: hex("success"), danger: hex("danger")))
        webView?.backgroundColor = UIColor(Theme.canvas)
        webView?.scrollView.backgroundColor = UIColor(Theme.canvas)
    }

    private func haptic(_ style: String?) {
        switch style {
        case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
        case "selection": UISelectionFeedbackGenerator().selectionChanged()
        default: UIImpactFeedbackGenerator(style: style == "medium" ? .medium : .light).impactOccurred()
        }
    }

    /// A web page inside the app, so Mycroft stays active (iOS would suspend it in Safari).
    func present(_ url: URL) {
        guard url.scheme == "https" || url.scheme == "http", let top = Self.topController() else { return }
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor(Theme.accentSoft)
        controller.dismissButtonStyle = .done
        safari = controller
        top.present(controller, animated: true)
    }

    static func topController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    // MARK: JSON

    /// A page value as a JSON object (tool arguments).
    static func json(_ value: Any?) throws -> JSONObject {
        guard let value, !(value is NSNull) else { return [:] }
        guard JSONSerialization.isValidJSONObject(value),
            case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value))
        else { throw BridgeError("Tool arguments must be an object") }
        return object
    }

    static func object(_ value: some Encodable) -> Any? {
        guard let data = try? JSONEncoder.iso.encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Sorted keys: feeds compare this text to skip unchanged updates, and a dictionary's order isn't stable.
    static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Keeps transcripts light for the page: huge tool outputs are cut, huge images left out.
    static func slim(_ value: Any) -> Any {
        if var dictionary = value as? [String: Any] {
            if dictionary["type"] as? String == "image", let data = dictionary["data"] as? String, data.count > 600_000 {
                dictionary["data"] = nil
                dictionary["omitted"] = true
            }
            if dictionary["type"] as? String == "text", let text = dictionary["text"] as? String, text.count > 40_000 {
                dictionary["text"] = String(text.prefix(40_000)) + "\n… (\(text.count - 40_000) more characters)"
            }
            for (key, inner) in dictionary where inner is [Any] || inner is [String: Any] { dictionary[key] = slim(inner) }
            return dictionary
        }
        if let array = value as? [Any] { return array.map(slim) }
        return value
    }

    static let notices = """
        Mycroft's screen is built with Preact (MIT, © Jason Miller) and htm (Apache-2.0, © Google LLC), \
        bundled as htm's preact/standalone build.

        Mycroft's voice in a conversation is Phonon 31m by Gradium (Apache-2.0), https://huggingface.co/gradium/phonon-31m-en, \
        in FluidInference's Core ML conversion (https://huggingface.co/FluidInference/pocket-tts-coreml), run by FluidAudio.

        Dictation uses Fluid Speech Mini by FluidVoice (CC-BY-4.0), \
        https://huggingface.co/FluidVoice-Labs/fluid-speech-mini-coreml, built on NVIDIA's Parakeet TDT 0.6B v3 \
        (CC-BY-4.0, © NVIDIA Corporation) and Moondream's Parakeet Ultra (CC-BY-4.0, © Moondream), with FluidInference's \
        Parakeet v3 Core ML preprocessor (CC-BY-4.0). Mycroft runs it unchanged (its joint network file renamed for \
        FluidAudio) through FluidAudio (Apache-2.0, © FluidInference). License: https://creativecommons.org/licenses/by/4.0/

        """ + PiDurable.thirdPartyNotices
}

nonisolated struct BridgeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The arguments of a call from the page.
struct Args {
    let values: [String: Any]
    init(_ values: [String: Any]) { self.values = values }

    func string(_ key: String) -> String? { values[key] as? String }
    func bool(_ key: String) -> Bool? { (values[key] as? NSNumber)?.boolValue }
    func int(_ key: String) -> Int? { (values[key] as? NSNumber)?.intValue ?? (values[key] as? String).flatMap(Int.init) }

    func require<T>(_ key: String) throws -> T {
        if T.self == Int.self, let value = int(key) as? T { return value }
        guard let value = values[key] as? T else { throw BridgeError("Missing \(key)") }
        return value
    }
}
