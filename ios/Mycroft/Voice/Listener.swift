import AVFoundation
import Foundation
import Observation
import os

/// Dictation in every thread, on the iPhone itself (docs/decisions/0010-voice-in-every-thread.md, 0011, 0014, 0017).
///
/// One listener, for one thread's composer at a time, with Fluid Speech Mini (bundled, English): the words so far are
/// transcribed again every second and at every pause, so the text arrives in short steps, and the final text is always
/// one pass over everything said. Audio heard before the model has loaded is kept and transcribed once it has.
///
/// Only speech is transcribed: Apple's sound classifier marks it (``SpeechActivity``), and the words start where it
/// first heard speech. Until then nothing is transcribed and only the last few seconds of audio are kept.
///
/// The user starts and stops it; nothing is sent on a pause. The composer holds the mic (release sends) or taps it
/// (tap again, or send). `stop()` hands back the words and the page sends them like typed text.
///
/// Listening runs here, not in the web page, so it carries on with the screen locked (the app has background audio).
/// The page shows `snapshot()` and drives it with the methods below.
///
/// In a conversation (``VoiceChat``) it plays Mycroft's voice through the same engine, with echo cancellation on the
/// speaker (none with headphones, and it switches when they come or go), and hands over each turn with ``take()``
/// while it goes on listening.
@Observable
final class Listener {
    enum State: Equatable {
        case off, preparing, on
        case failed(String)
    }

    private(set) var state: State = .off
    /// Whose composer is listening: a thread id, or a new thread's draft id.
    private(set) var owner: String?
    /// What the user has said.
    private(set) var text = ""
    /// Typed text the words go after.
    private(set) var prefix = ""
    /// Microphone level 0…1.
    private(set) var level: Double = 0
    /// When listening started, for the timer.
    private(set) var startedAt: Date?
    private(set) var lastError: String?
    /// What Mycroft says is taken out of what the microphone hears (in a conversation; with headphones nothing comes
    /// back to take out). Without it the conversation doesn't listen while Mycroft speaks.
    private(set) var echoCancelled = false

    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var speech = SpeechActivity()
    @ObservationIgnored nonisolated(unsafe) private var classifier: SpeechClassifier?
    /// In a conversation: the voice that plays through this engine.
    @ObservationIgnored private var speaker: Speaker?
    /// The route a conversation's audio is set up for: headphones (no echo cancellation) or the speaker.
    @ObservationIgnored private var setUpForHeadphones = false
    @ObservationIgnored private var routeChanges: NSObjectProtocol?
    @ObservationIgnored private var rerouting: Task<Void, Never>?
    /// When the conversation's audio last restarted for a new route.
    @ObservationIgnored private var reroutes: [Date] = []
    /// Audio time where the words start: earlier results were cleared.
    @ObservationIgnored private var turnStart: Double = 0
    /// Counts clears, so a transcription that finishes after its words were cleared is dropped.
    @ObservationIgnored private var turn = 0
    @ObservationIgnored private var framesFed: Int64 = 0
    @ObservationIgnored private let engineIO = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored nonisolated(unsafe) private var converter: AVAudioConverter?
    @ObservationIgnored private let log = Logger(subsystem: "dev.mycroft", category: "listener")

    /// The samples from `audioStart` (a frame index) on.
    @ObservationIgnored private var audio: [Float] = []
    @ObservationIgnored private var audioStart: Int64 = 0
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    /// Audio time the shown text covers, and what the last pass took.
    @ObservationIgnored private var refreshedThrough: Double = 0
    @ObservationIgnored private var refreshCost: Double = 0

    /// The format the tone is played in.
    nonisolated static let playFormat = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
    /// The format the model takes: 16 kHz mono.
    nonisolated static let modelFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: FluidSpeech.sampleRate, channels: 1, interleaved: false)!
    nonisolated static let sampleRate = FluidSpeech.sampleRate
    /// Audio kept before the window where speech was first heard, for a word's soft start.
    static let preRoll = 0.2
    /// Audio kept after the last speech when a turn is handed over, for a word's soft end.
    static let speechTail = 0.3

    /// Audio seconds heard: the clock the words are measured on.
    private var now: Double { Double(framesFed) / Self.sampleRate }
    private var listening: Bool { state == .on }
    /// Seconds since the user last spoke (or since the words were cleared).
    var quiet: Double { now - speech.lastSpeech }
    /// Headphones are connected (wired, AirPods, a car), so the microphone doesn't hear Mycroft. Told by the devices,
    /// not by where the sound goes now: that depends on how the audio is set up (with echo cancellation, iOS names the
    /// AirPods while it plays on the speaker; set up for the AirPods, it can name the speaker), and judging by it made a
    /// conversation switch between the two every second.
    var headphones: Bool {
        let session = AVAudioSession.sharedInstance()
        let outputs: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .carAudio]
        let inputs: Set<AVAudioSession.Port> = [.headsetMic, .bluetoothHFP, .bluetoothLE, .carAudio]
        return session.currentRoute.outputs.contains { outputs.contains($0.portType) }
            || (session.availableInputs ?? []).contains { inputs.contains($0.portType) }
    }

    /// The route's ports, for the journal.
    static var route: String {
        let route = AVAudioSession.sharedInstance().currentRoute
        let names = { (ports: [AVAudioSessionPortDescription]) in ports.map(\.portType.rawValue).joined(separator: ",") }
        return "in \(names(route.inputs)), out \(names(route.outputs))"
    }

    // MARK: Control

    /// Loads Fluid Speech Mini when the app starts, so dictation is transcribed at once. A load takes well under a
    /// second, except the first after an install or update (about 10 s on an iPhone 17 Pro Max, while Core ML prepares it
    /// for the Neural Engine).
    static func warm(_ app: AppModel) {
        guard FluidSpeech.isBundled else { return }
        Task {
            let log = Logger(subsystem: "dev.mycroft", category: "listener")
            let started = Date.now
            do {
                try await FluidSpeech.shared.load()
                app.dictationReady = true
                log.notice("fluid speech loaded in \(Date.now.timeIntervalSince(started), format: .fixed(precision: 2)) s")
            } catch {
                log.error("fluid speech failed to load: \(error)")
            }
        }
    }

    /// Listens for `owner`'s composer, after the typed `prefix`. With a `speaker`, for a conversation: with echo
    /// cancellation, and the speaker plays through the same engine.
    func start(_ owner: String, prefix: String = "", speaker: Speaker? = nil) async {
        if self.owner != owner {
            if self.speaker != nil || speaker != nil { close() }
            self.owner = owner
            clearWords()
        }
        self.prefix = prefix
        lastError = nil
        if state == .on { return }
        self.speaker = speaker
        startedAt = .now
        await open()
        if state == .on { tone() }
    }

    /// Stops listening and hands back the typed prefix and what was said, to send or to edit.
    @discardableResult
    func stop() async -> String {
        guard state != .off else { return "" }
        let words = await finish()
        let kept = [prefix, words].filter { !$0.isEmpty }.joined(separator: " ")
        prefix = ""
        close()
        return kept
    }

    /// Throws the words away and stops.
    func cancel() {
        clearWords()
        prefix = ""
        close()
    }

    /// Throws away the typed prefix and the words so far, and keeps listening: starting over.
    func clear() {
        clearWords()
        prefix = ""
    }

    /// The words so far, finished, and listening goes on with none: one turn of a conversation.
    func take() async -> String {
        guard listening else { return "" }
        let cut = now
        // The pause that ended the turn is nothing to transcribe.
        let words = await finish(through: min(cut, speech.lastSpeech + Self.speechTail))
        clearWords(from: cut)
        return words
    }

    /// A lower tone: the words went to Mycroft.
    func sent() {
        tone(frequency: 587)
    }

    /// The thread's screen went away, or the app was closed.
    func shutDown() {
        close()
        owner = nil
    }

    /// What the page shows.
    func snapshot() -> [String: Any] {
        var state: [String: Any] = [
            "owner": owner ?? NSNull(), "text": text,
            "prefix": prefix, "level": (level * 100).rounded() / 100, "error": lastError ?? NSNull(),
            "elapsed": startedAt.map { Int(Date.now.timeIntervalSince($0) * 1000) } ?? 0,
        ]
        switch self.state {
        case .off: state["state"] = "off"
        case .preparing: state["state"] = "preparing"
        case .on: state["state"] = "on"
        case .failed(let message): state["state"] = "failed"; state["error"] = message
        }
        return state
    }

    // MARK: Words

    /// The words start again at `start` (now, unless given).
    private func clearWords(from start: Double? = nil) {
        let start = start ?? now
        text = ""
        turnStart = start
        turn += 1
        refreshedThrough = start
        speech.reset(at: start)
        dropAudio(before: start)
    }

    private func dropAudio(before time: Double) {
        let drop = Int(min(max(0, Int64(time * Self.sampleRate) - audioStart), Int64(audio.count)))
        audio.removeFirst(drop)
        audioStart += Int64(drop)
    }

    /// Everything said (through audio time `cut`, by default all of it), finalized; nothing without speech.
    private func finish(through cut: Double? = nil) async -> String {
        guard listening else { return text }
        guard speech.heard else { return "" }
        let cut = cut ?? now
        let turn = turn
        // The shown text already covers it all unless the user was still talking.
        if refreshedThrough < speech.lastSpeech + 0.2 {
            do {
                text = try await FluidSpeech.shared.transcribe(samples(through: cut))
            } catch {
                lastError = error.localizedDescription
            }
        }
        // Cleared while it finished.
        return self.turn == turn ? text : ""
    }

    /// Every tenth of a second: Fluid Speech Mini's passes.
    private func tick() {
        guard listening else { return }
        refreshIfDue()
    }

    // MARK: Passes

    /// This turn's samples from where speech starts, up to audio time `end`.
    private func samples(through end: Double) -> [Float] {
        let start = max(turnStart, (speech.onset ?? turnStart) - Self.preRoll)
        let from = Int(max(0, Int64(start * Self.sampleRate) - audioStart))
        let to = Int(min(max(0, Int64(end * Self.sampleRate) - audioStart), Int64(audio.count)))
        return from < to ? Array(audio[from..<to]) : []
    }

    /// Fluid Speech Mini has no live results: the turn so far is transcribed again every second or so while the user
    /// speaks, and as soon as they pause, so the text is current before a pause ends the turn.
    private func refreshIfDue() {
        guard refreshing == nil, speech.heard else { return }
        let spoke = speech.lastSpeech > refreshedThrough
        let paused = spoke && now - speech.lastSpeech >= 0.3
        // Long turns take longer to transcribe again: don't run back to back.
        let due = now - refreshedThrough >= max(1.0, refreshCost * 3)
        guard paused || (due && spoke) else { return }
        let through = now
        let turn = turn
        let samples = samples(through: through)
        refreshing = Task { [weak self] in
            let started = Date.now
            let words: String?
            do {
                words = try await FluidSpeech.shared.transcribe(samples)
            } catch {
                self?.log.error("fluid speech: \(error)")
                words = nil
            }
            guard let self else { return }
            self.refreshing = nil
            guard self.turn == turn, self.listening else { return }
            self.refreshCost = Date.now.timeIntervalSince(started)
            self.refreshedThrough = through
            if let words { self.text = words }
        }
    }

    // MARK: Audio

    private func open() async {
        state = .preparing
        do {
            guard FluidSpeech.isBundled else {
                throw VoiceError("This build of Mycroft doesn't include Fluid Speech Mini (run ios/scripts/fetch-fluid-speech.sh).")
            }
            guard await AVAudioApplication.requestRecordPermission() else {
                throw VoiceError("Mycroft needs the microphone. Allow it in Settings → Mycroft.")
            }
            framesFed = 0
            audio = []
            audioStart = 0
            refreshCost = 0
            // On the same clock as the words: it is fed what they are, from the first frame.
            classifier = try SpeechClassifier(format: Self.modelFormat) { [weak self] confidence, time in
                Task { @MainActor in self?.speech.score(confidence, at: time) }
            }
            try startAudio()
            clearWords()
            // Stopped or cancelled while it started: don't leave the microphone on.
            guard state == .preparing else { return teardown() }
            state = .on
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    self?.tick()
                }
            }
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        log.error("listener failed: \(error)")
        state = .failed(error.localizedDescription)
        teardown()
    }

    private func close() {
        guard state != .off else { return }
        teardown()
        state = .off
        level = 0
        startedAt = nil
    }

    private func teardown() {
        ticker?.cancel()
        ticker = nil
        refreshing?.cancel()
        refreshing = nil
        engineIO.inputNode.removeTap(onBus: 0)
        engineIO.stop()
        classifier?.stop()
        classifier = nil
        audio = []
        if let routeChanges { NotificationCenter.default.removeObserver(routeChanges) }
        routeChanges = nil
        rerouting?.cancel()
        rerouting = nil
        if speaker != nil {
            speaker?.stop()
            speaker = nil
            if engineIO.inputNode.isVoiceProcessingEnabled { try? engineIO.inputNode.setVoiceProcessingEnabled(false) }
            if AVAudioSession.sharedInstance().prefersEchoCancelledInput { try? AVAudioSession.sharedInstance().setPrefersEchoCancelledInput(false) }
        }
        echoCancelled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startAudio() throws {
        let session = AVAudioSession.sharedInstance()
        if speaker != nil {
            try startConversationAudio(session)
        } else {
            // No voice processing: it is made for calls and smears speech for a recognizer. AirPods that can record at
            // full bandwidth are used (never their narrow-band call microphone); otherwise the iPhone's own microphone,
            // with the least processing iOS offers.
            try session.setCategory(
                .playAndRecord, mode: .default, options: [.bluetoothHighQualityRecording, .allowBluetoothA2DP, .defaultToSpeaker])
            try session.setActive(true)
            let fullBandwidth = session.currentRoute.inputs.contains { $0.bluetoothMicrophoneExtension?.highQualityRecording.isEnabled == true }
            if !fullBandwidth { try session.setMode(.measurement) }
        }
        if player.engine == nil {
            engineIO.attach(player)
            engineIO.connect(player, to: engineIO.mainMixerNode, format: Self.playFormat)
        }
        speaker?.connect(to: engineIO)
        // The tap takes the microphone's own format, whatever it is by now: echo cancellation changes it after the
        // session is set up, and a tap in a stale format throws. The converter follows the buffers (`captured`).
        let node = engineIO.inputNode
        converter = nil
        node.installTap(onBus: 0, bufferSize: 2048, format: nil, block: AudioTap.block { [weak self] buffer in
            self?.captured(buffer)
        })
        engineIO.prepare()
        try engineIO.start()
        player.play()
        speaker?.player.play()
        if speaker != nil, routeChanges == nil {
            routeChanges = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.routeChanged() }
            }
        }
    }

    /// Headphones came or went in a conversation: echo cancellation has to go on or off, and the engine restart with
    /// it. Route changes come in bursts (and setting the session up makes its own), so it settles first.
    private func routeChanged() {
        rerouting?.cancel()
        rerouting = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.reroute()
        }
    }

    private func reroute() {
        guard let speaker, state == .on, headphones != setUpForHeadphones else { return }
        // Restarting changes the route too: if that keeps asking for another restart, stay as it is.
        reroutes = reroutes.filter { $0 > .now - 10 } + [.now]
        guard reroutes.count <= 3 else {
            if reroutes.count == 4 { Journal.note("talk_route_loop", ["headphones": "\(headphones)", "route": Self.route]) }
            return
        }
        log.notice("conversation audio: route changed, headphones: \(self.headphones)")
        Journal.note("talk_route", ["headphones": "\(headphones)", "route": Self.route])
        // What Mycroft was saying starts again on the new route, from the sentence it was in.
        let unsaid = speaker.halt()
        engineIO.inputNode.removeTap(onBus: 0)
        engineIO.stop()
        do {
            try startAudio()
        } catch {
            return fail(error)
        }
        for sentence in unsaid { speaker.say(sentence) }
    }

    /// A conversation's microphone stays on while Mycroft speaks, so the user can cut in: Mycroft's voice must be taken
    /// out of what it hears. The system's echo-cancelled input where the route has it, otherwise voice processing (a
    /// call's processing, which also cancels echo). With headphones nothing comes back to cancel.
    private func startConversationAudio(_ session: AVAudioSession) throws {
        #if targetEnvironment(simulator)
        // The Simulator's audio server times out (and aborts the app) on echo cancellation and voice processing: the
        // composer's setup, and no cutting in.
        try session.setCategory(
            .playAndRecord, mode: .default, options: [.bluetoothHighQualityRecording, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setActive(true)
        echoCancelled = false
        setUpForHeadphones = headphones
        log.notice("conversation audio: no echo cancellation in the Simulator")
        return
        #endif
        if engineIO.inputNode.isVoiceProcessingEnabled { try engineIO.inputNode.setVoiceProcessingEnabled(false) }
        if session.prefersEchoCancelledInput { try? session.setPrefersEchoCancelledInput(false) }
        echoCancelled = false
        try session.setCategory(
            .playAndRecord, mode: .default, options: [.bluetoothHighQualityRecording, .allowBluetoothA2DP, .defaultToSpeaker])
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
        // Headphones: nothing comes back to cancel. Echo cancellation would also take the sound off them: it can't play
        // to AirPods' music profile, so iOS moves Mycroft's voice to the iPhone's speaker (while still reporting the
        // AirPods), where the microphone hears it. Nor does dictation's measurement mode suit: with the iPhone's own
        // microphone, it too moves the sound to the speaker. So the default mode, which leaves it on the headphones.
        setUpForHeadphones = headphones
        if setUpForHeadphones {
            log.notice("conversation audio: headphones, no echo cancellation")
            return
        }
        if session.isEchoCancelledInputAvailable {
            try? session.setPrefersEchoCancelledInput(true)
            try session.setActive(true)
            // A preference, not a guarantee: the route decides.
            if session.isEchoCancelledInputEnabled {
                echoCancelled = true
                log.notice("conversation audio: echo-cancelled input")
                return
            }
            try? session.setPrefersEchoCancelledInput(false)
        }
        do {
            try engineIO.inputNode.setVoiceProcessingEnabled(true)
            echoCancelled = true
            log.notice("conversation audio: voice processing")
        } catch {
            log.error("conversation audio: no echo cancellation (\(error))")
        }
    }

    nonisolated private func captured(_ buffer: AVAudioPCMBuffer) {
        let rms = Self.rms(buffer)
        var output = buffer
        let format = Self.modelFormat
        if buffer.format != format {
            if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
            guard let converter else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate + 32)
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil else { return }
            output = converted
        }
        let frames = Int64(output.frameLength)
        guard let channel = output.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        Task { @MainActor in
            guard self.listening || self.state == .preparing else { return }
            self.audio += samples
            self.classifier?.analyze(samples)
            self.heardAudio(frames: frames, rms: rms)
        }
    }

    private func heardAudio(frames: Int64, rms: Double) {
        framesFed += frames
        level = level * 0.6 + min(1, rms * 8) * 0.4
        // Before speech, only what the classifier's first window and the pre-roll can reach back to is needed.
        if !speech.heard, Double(audio.count) / Self.sampleRate > 4 { dropAudio(before: now - 2) }
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
        return Double(sqrt(sum / Float(buffer.frameLength)))
    }

    // MARK: Tone

    /// A short, quiet cue that the microphone is on, so the screen needn't be watched.
    private func tone(frequency: Double = 880) {
        guard engineIO.isRunning else { return }
        let format = Self.playFormat
        let count = Int(format.sampleRate * 0.06)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
            let samples = buffer.floatChannelData?[0]
        else { return }
        for frame in 0..<count {
            // A raised-cosine envelope: no clicks at either end.
            let envelope = 0.5 - 0.5 * cos(2 * Double.pi * Double(frame) / Double(count))
            samples[frame] = Float(sin(2 * Double.pi * frequency * Double(frame) / format.sampleRate) * envelope * 0.12)
        }
        buffer.frameLength = AVAudioFrameCount(count)
        player.scheduleBuffer(buffer)
    }
}
