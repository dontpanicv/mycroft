import Foundation
import Observation
import PiDurableKit
import os

/// Conversation mode in a thread (docs/decisions/0016-conversation-mode.md): the user talks, Mycroft answers aloud,
/// hands-free, until the user ends it.
///
/// - **Hearing.** The listener stays on with echo cancellation, and transcribes only what Apple's sound classifier calls
///   speech. A pause after the user's words ends their turn (short after a finished sentence, long after "and…"), and
///   the words go to the thread like typed text, as a steer while a run works.
/// - **Speaking.** It follows the thread's views and says each new sentence of the run's text as it streams (the
///   agent is asked to say what it is about to do before it uses tools), in Phonon's voice (``Speaker``).
/// - **Cutting in.** With headphones, the user's words stop the voice at once, and what was left unsaid is dropped.
///   On the iPhone's speaker, echo cancellation leaves enough of Mycroft's voice for the recognizer to turn into words
///   (garbled, so they can't be told from the user's), so only "stop", "wait" and the like cut in there. A tap on the
///   orb always does. What the microphone heard while Mycroft spoke, and for a moment after, is never sent.
///
/// Ending it stops the microphone and the voice, never the run. It runs natively, so it goes on with the screen locked.
@Observable
final class VoiceChat {
    enum Phase: String {
        case off, starting, listening, hearing, working, speaking
    }

    private(set) var phase: Phase = .off
    /// The thread it talks in; nil until a new thread's first words create it.
    private(set) var thread: ConversationID?
    /// What the user is saying now.
    private(set) var heard = ""
    /// What Mycroft is doing, while it works: the headline of its thinking, or a tool.
    private(set) var status: String?
    /// The microphone is ignored (it stays on for echo cancellation).
    private(set) var muted = false
    private(set) var error: String?
    private(set) var startedAt: Date?

    var isOn: Bool { phase != .off }

    private let listener: Listener
    private let speaker = Speaker.shared
    private var app: AppModel { AppModel.shared }
    @ObservationIgnored private var narration = Narration()
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var narrator: Task<Void, Never>?
    @ObservationIgnored private var sending = false
    /// The thread's run is working, as its views last said.
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var wasSpeaking = false
    /// Until then, what the microphone hears is still Mycroft's voice: the room's echo and the speaker's latency after
    /// the last sentence played.
    @ObservationIgnored private var echoUntil = Date.distantPast
    /// How long Mycroft's voice lingers in the microphone after it stops.
    static let echoTail: TimeInterval = 0.7
    @ObservationIgnored private let log = Logger(subsystem: "dev.mycroft", category: "voice-chat")

    static let owner = "talk"

    init(listener: Listener) {
        self.listener = listener
    }

    // MARK: Control

    /// Starts talking in thread `id`, or in a new thread when nil.
    func start(thread id: Int?) async {
        let target = id.map { ConversationID($0) }
        if isOn {
            if target == thread { return }
            end()
        }
        phase = .starting
        error = nil
        heard = ""
        status = nil
        muted = false
        thread = target
        startedAt = .now
        narration = Narration()
        guard Speaker.isBundled else {
            return fail("This build of Mycroft doesn't include its voice (run ios/scripts/fetch-phonon.sh).")
        }
        // The voice loads while the microphone starts: the user speaks first anyway.
        Task { [speaker, log] in
            do { try await speaker.load() } catch { log.error("phonon failed to load: \(error)") }
        }
        await listener.start(Self.owner, speaker: speaker)
        if case .failed(let message) = listener.state { return fail(message) }
        guard phase == .starting, listener.state == .on else { return }
        if let target {
            follow(target)
            await setVoice(true, in: target)
        }
        phase = .listening
        Journal.note("talk_started", [
            "echoCancelled": "\(listener.echoCancelled)", "dictationReady": "\(app.dictationReady)",
            "headphones": "\(listener.headphones)", "voiceReady": "\(speaker.ready)", "route": Listener.route,
        ])
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self?.step()
            }
        }
    }

    /// Stops listening and speaking, and leaves the thread's run alone.
    func end() {
        guard isOn else { return }
        ticker?.cancel()
        ticker = nil
        narrator?.cancel()
        narrator = nil
        speaker.stop()
        if listener.owner == Self.owner { listener.shutDown() }
        if let thread { Task { await setVoice(false, in: thread) } }
        phase = .off
        thread = nil
        heard = ""
        status = nil
        muted = false
        startedAt = nil
    }

    /// The orb: stops Mycroft speaking, or sends what the user said without waiting for the pause.
    func tap() {
        if speaker.isSpeaking {
            interrupt()
            // What the microphone held was Mycroft's voice.
            listener.clear()
        } else if !listener.text.isEmpty {
            send()
        }
    }

    func mute(_ on: Bool) {
        muted = on
        if on { listener.clear() }
    }

    /// What the page shows.
    func snapshot() -> [String: Any] {
        [
            "phase": phase.rawValue, "thread": thread?.rawValue ?? NSNull(), "heard": heard,
            "said": speaker.current ?? NSNull(), "status": status ?? NSNull(), "muted": muted,
            "error": error ?? NSNull(), "voiceReady": speaker.ready, "cutIn": cutIn.rawValue,
            "level": ((phase == .speaking ? speaker.level : listener.level) * 100).rounded() / 100,
            "elapsed": startedAt.map { Int(Date.now.timeIntervalSince($0) * 1000) } ?? 0,
        ]
    }

    /// How the user can cut Mycroft off while it speaks.
    enum CutIn: String {
        /// Talking (headphones: nothing comes back).
        case words
        /// "Stop", "wait"… (the speaker, with echo cancellation).
        case stop
        /// Only the orb (no echo cancellation).
        case tap
    }

    var cutIn: CutIn {
        // Echo cancellation is on only when the conversation started on the speaker.
        if listener.echoCancelled { return .stop }
        return listener.headphones ? .words : .tap
    }

    // MARK: The loop

    /// Every tenth of a second: the user's turn, cutting in, and the phase.
    private func step() {
        guard isOn else { return }
        if case .failed(let message) = listener.state { return fail(message) }
        let speaking = speaker.isSpeaking
        // After this step: cutting in stops the voice, and what follows is the user, not an echo.
        defer { wasSpeaking = speaker.isSpeaking }
        let words = listener.text
        if muted {
            if !words.isEmpty { listener.clear() }
            phase = speaking ? .speaking : busy ? .working : .listening
            return
        }
        if speaking {
            phase = .speaking
            let cuts = switch cutIn {
            case .words: !Echo.isEcho(words, of: speaker.said)
            case .stop: Echo.interrupts(words, of: speaker.said)
            case .tap: false
            }
            if !words.isEmpty, cuts {
                log.notice("cut in: \(words, privacy: .private)")
                Journal.note("talk_cut", ["mode": cutIn.rawValue, "words": words])
                interrupt()
                if cutIn == .words {
                    heard = words
                    phase = .hearing
                } else {
                    // "Stop" is the whole message; the rest was Mycroft's echo. The user goes on afresh.
                    listener.clear()
                    phase = busy ? .working : .listening
                }
            } else if !words.isEmpty, listener.quiet > 0.3 {
                // Mycroft's own voice, transcribed: dropped at each pause, so it is never sent and each pass stays short.
                listener.clear()
            }
            return
        }
        // It just stopped speaking: everything heard while it spoke, and its echo for a moment after, was its own
        // voice. The transcription of it can arrive after the voice ends, so the audio itself is dropped.
        if wasSpeaking {
            if !words.isEmpty { Journal.note("talk_echo_dropped", ["words": words]) }
            listener.clear()
            echoUntil = .now + Self.echoTail
        }
        if Date.now < echoUntil {
            if !words.isEmpty { listener.clear() }
            heard = ""
            phase = busy ? .working : .listening
            return
        }
        heard = words
        if words.isEmpty {
            phase = busy ? .working : .listening
        } else {
            phase = .hearing
            if listener.quiet >= TurnEnd.pause(after: words) { send() }
        }
    }

    /// The user's turn, to the thread: a new message, or a steer while a run works.
    private func send() {
        guard !sending else { return }
        sending = true
        Task {
            await deliver()
            sending = false
        }
    }

    private func deliver() async {
        let text = await listener.take().trimmingCharacters(in: .whitespacesAndNewlines)
        heard = ""
        guard isOn, !text.isEmpty else { return }
        // Nothing to say ("." from a cough or a breath).
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else {
            Journal.note("talk_dropped", ["reason": "no words", "text": text])
            return
        }
        Journal.note("talk_sent", ["text": text, "cutIn": cutIn.rawValue])
        listener.sent()
        if speaker.isSpeaking { interrupt() }
        do {
            if let thread {
                guard let meta = app.thread(thread) else {
                    throw Failure("This thread no longer exists.")
                }
                // Always a steer: talking to Mycroft while it works redirects it. (An idle thread takes it as a new
                // message; `busy` from the last view can be a moment late.)
                try await app.send(text, to: meta, whenBusy: .steer)
            } else {
                let meta = try await app.startThread(with: text, voice: true)
                guard isOn else { return }
                thread = meta.id
                follow(meta.id)
            }
            error = nil
        } catch {
            log.error("send failed: \(error)")
            self.error = error.localizedDescription
        }
    }

    /// Stops the voice and drops what was left to say.
    private func interrupt() {
        speaker.stop()
        narration.skip()
    }

    private func fail(_ message: String) {
        log.error("conversation failed: \(message)")
        Journal.note("talk_failed", ["error": message, "route": Listener.route])
        end()
        error = message
    }

    // MARK: The thread

    /// Follows the thread and says what its runs write from now on.
    private func follow(_ id: ConversationID) {
        narrator?.cancel()
        narrator = Task { [weak self] in
            guard let conversation = try? await self?.app.conversation(id) else { return }
            var first = true
            do {
                for try await view in conversation.views() {
                    guard let self, !Task.isCancelled, self.thread == id else { return }
                    self.saw(view, first: first)
                    first = false
                }
            } catch {
                self?.log.error("thread views ended: \(error)")
            }
        }
    }

    private func saw(_ view: ConversationView, first: Bool) {
        busy = view.isBusy
        let (anchor, pieces) = Self.runText(view)
        if first {
            // What was there before the conversation started isn't read out.
            narration.skip(anchor: anchor, pieces: pieces)
        } else {
            for sentence in narration.update(anchor: anchor, pieces: pieces, streaming: view.streamingMessage != nil) {
                speaker.say(sentence)
            }
        }
        status = view.isBusy ? Self.status(view) : nil
    }

    /// The text of the newest run: the user message it answers (by entry id), and the text blocks after it, the one
    /// being written last.
    static func runText(_ view: ConversationView) -> (anchor: String?, pieces: [String]) {
        let start = view.entries.lastIndex { $0.kind == .user }
        let anchor = start.map { String(view.entries[$0].id.rawValue) }
        let after = start.map { view.entries[($0 + 1)...] } ?? view.entries[...]
        let messages = after.compactMap(\.assistantMessage) + [view.streamingMessage].compactMap { $0 }
        let pieces = messages.flatMap { message in
            message.content.compactMap { block -> String? in
                if case .text(let text) = block { return text }
                return nil
            }
        }
        return (anchor, pieces)
    }

    /// What a working run is doing, in a few words: the tool running, or the headline of its thinking.
    static func status(_ view: ConversationView) -> String {
        if let tool = view.live.tools.last(where: { $0.status == .running }) {
            return "Running \(tool.name)"
        }
        if let thinking = view.streamingMessage?.thinking, !thinking.isEmpty {
            // Reasoning summaries open each part with a bold headline ("**Checking the build**"): the newest one.
            if let headline = thinking.matches(of: /\*\*([^*\n]+)\*\*/).last?.output.1 {
                return String(headline).trimmingCharacters(in: .whitespaces)
            }
            let line = thinking.split(whereSeparator: \.isNewline).last.map(String.init) ?? thinking
            return String(line.prefix(80))
        }
        return "Thinking"
    }

    /// Asks the agent to talk while the conversation is on (AppModel.instructions).
    private func setVoice(_ on: Bool, in id: ConversationID) async {
        do {
            try await app.setVoice(on, in: id)
        } catch {
            log.error("voice instructions failed: \(error)")
        }
    }
}
