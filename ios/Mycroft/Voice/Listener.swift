import AVFoundation
import Foundation
import Observation
import PiDurableKit
import Speech
import os

/// Voice in every thread, on the iPhone itself (docs/decisions/0010-voice-in-every-thread.md).
///
/// One listener, for one thread at a time, with the model chosen in Settings ([`Dictation`]):
/// - **Parakeet** (bundled): the turn so far is transcribed again every second and at every pause, so the text
///   arrives in short steps, and the sent text is always one pass over the whole turn.
/// - **Apple** (SpeechTranscriber, English): words appear as they are spoken.
///
/// Two ways to talk:
/// - **hold:** the screen holds the mic button; releasing sends.
/// - **auto:** a pause ends the turn ([`TurnDetector`]); after a short countdown the turn is sent. Talking again
///   cancels the countdown; "send it" sends at once, "scratch that" throws the turn away.
///
/// The loop runs here, not in the web page, so it carries on with the screen locked (the app has background audio).
/// The page shows `snapshot()` and steers with the methods below.
@Observable
final class Listener {
    enum State: Equatable {
        case off, preparing, on
        case failed(String)
    }

    enum Mode: String {
        case hold, auto
    }

    private(set) var state: State = .off
    private(set) var mode: Mode = .auto
    private(set) var thread: ThreadMeta?
    /// The model this session listens with.
    private(set) var engine: Dictation = .apple
    /// Parakeet is still loading; what is said meanwhile is kept and transcribed once it is ready.
    private(set) var loadingModel = false
    /// What the user is saying in this turn.
    private(set) var text = ""
    /// Typed text the turn goes after.
    private(set) var prefix = ""
    /// Microphone level 0…1.
    private(set) var level: Double = 0
    /// When the pause-to-send fires.
    private(set) var sendsAt: Date?
    /// Counts sends, so the page clears its draft once per send.
    private(set) var sent = 0
    private(set) var lastError: String?

    /// How long the countdown runs between the pause and sending.
    static let countdown: TimeInterval = 1.0

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var detector = TurnDetector()
    /// Audio time where this turn starts: earlier results belong to the previous one.
    @ObservationIgnored private var turnStart: Double = 0
    /// Counts turns, so a transcription that finishes after its turn ended is dropped.
    @ObservationIgnored private var turn = 0
    /// A turn is being finished; the countdown waits.
    @ObservationIgnored private var committing = false
    @ObservationIgnored private var framesFed: Int64 = 0
    @ObservationIgnored private var sampleRate: Double = 16_000
    @ObservationIgnored private let engineIO = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored nonisolated(unsafe) private var converter: AVAudioConverter?
    /// The format the model takes.
    @ObservationIgnored nonisolated(unsafe) private var format: AVAudioFormat?
    @ObservationIgnored nonisolated(unsafe) private var collectsSamples = false
    @ObservationIgnored private let log = Logger(subsystem: "dev.mycroft", category: "listener")

    // Apple's recognizer
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var input: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var results: Task<Void, Never>?
    @ObservationIgnored private var finalized = ""
    @ObservationIgnored private var volatile = ""

    // Parakeet
    /// The samples from `audioStart` (a frame index) on: this turn's audio, and what came after.
    @ObservationIgnored private var audio: [Float] = []
    @ObservationIgnored private var audioStart: Int64 = 0
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    /// Audio time the shown text covers, and what the last pass took.
    @ObservationIgnored private var refreshedThrough: Double = 0
    @ObservationIgnored private var refreshCost: Double = 0

    /// The format the tones are played in.
    nonisolated static let playFormat = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
    nonisolated static let parakeetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Parakeet.sampleRate, channels: 1, interleaved: false)!

    /// Audio seconds heard: the clock the turn is measured on.
    private var now: Double { Double(framesFed) / sampleRate }
    private var listening: Bool { state == .on }

    // MARK: Control

    /// Loads Parakeet ahead of the first turn, when a thread opens.
    static func warm(_ app: AppModel) {
        guard app.dictation == .parakeet, Parakeet.isBundled else { return }
        Task { try? await Parakeet.shared.load() }
    }

    /// Listens for `thread`. A different thread's turn is dropped; the same thread's goes on.
    func start(_ thread: ThreadMeta, mode: Mode, prefix: String = "", app: AppModel) async {
        self.app = app
        if self.thread?.id != thread.id {
            self.thread = thread
            clearTurn()
        }
        self.mode = mode
        self.prefix = prefix
        sendsAt = nil
        lastError = nil
        if state == .on { return }
        await open(app.dictation)
        if state == .on { tone(.listening) }
    }

    /// Hold became hands-free (the button was slid up), or the reverse.
    func setMode(_ mode: Mode) {
        self.mode = mode
        sendsAt = nil
    }

    /// Sends what was said now: the button was released, or tapped.
    func send() async {
        await commitAndSend()
    }

    /// Stops listening and hands back what was said (with the typed prefix), for the composer to edit.
    @discardableResult
    func stop() async -> String {
        guard state != .off else { return "" }
        let words = await commit()
        let kept = [prefix, words].filter { !$0.isEmpty }.joined(separator: " ")
        prefix = ""
        close()
        return kept
    }

    /// Throws the turn away and stops.
    func cancel() {
        clearTurn()
        close()
    }

    /// The thread's screen went away, or the app was closed.
    func shutDown() {
        close()
        thread = nil
    }

    /// What the page shows.
    func snapshot() -> [String: Any] {
        var state: [String: Any] = [
            "thread": thread?.id.rawValue ?? NSNull(), "mode": mode.rawValue, "engine": engine.rawValue,
            "loading": loadingModel, "text": text, "prefix": prefix, "level": (level * 100).rounded() / 100,
            "sent": sent, "error": lastError ?? NSNull(),
            "sendsIn": sendsAt.map { max(0, Int($0.timeIntervalSinceNow * 1000)) } ?? NSNull(),
            "countdown": Int(Self.countdown * 1000),
        ]
        switch self.state {
        case .off: state["state"] = "off"
        case .preparing: state["state"] = "preparing"
        case .on: state["state"] = "on"
        case .failed(let message): state["state"] = "failed"; state["error"] = message
        }
        return state
    }

    // MARK: Turns

    /// A new turn starts at `start` (now, unless given).
    private func clearTurn(from start: Double? = nil) {
        let start = start ?? now
        finalized = ""
        volatile = ""
        text = ""
        sendsAt = nil
        turnStart = start
        turn += 1
        refreshedThrough = start
        detector.reset(at: start)
        let drop = Int(min(max(0, Int64(start * sampleRate) - audioStart), Int64(audio.count)))
        audio.removeFirst(drop)
        audioStart += Int64(drop)
    }

    /// Finalizes everything heard so far and returns this turn's words; the next turn starts here.
    private func commit() async -> String {
        guard listening else {
            let words = text
            clearTurn()
            return VoiceCommand.parse(words).text
        }
        let cut = now
        let turn = turn
        committing = true
        defer { committing = false }
        switch engine {
        case .apple:
            try? await analyzer?.finalize(through: CMTime(seconds: cut, preferredTimescale: 48_000))
            // The final results for everything through the cut arrive right after.
            for _ in 0..<10 where !volatile.isEmpty { try? await Task.sleep(for: .milliseconds(30)) }
        case .parakeet:
            // The shown text already covers the turn unless the user was still talking.
            if refreshedThrough < detector.lastVoice + 0.2 {
                do {
                    text = try await Parakeet.shared.transcribe(samples(through: cut))
                } catch {
                    lastError = error.localizedDescription
                }
            }
        }
        // Cancelled while it finished.
        guard self.turn == turn else { return "" }
        let words = VoiceCommand.parse(text).text
        clearTurn(from: cut)
        return words
    }

    private func commitAndSend() async {
        sendsAt = nil
        let words = await commit()
        let message = [prefix, words].filter { !$0.isEmpty }.joined(separator: " ")
        prefix = ""
        guard !message.isEmpty, let thread, let app else { return }
        tone(.sent)
        sent += 1
        do {
            try await app.send(message, to: thread, steer: await app.isBusy(thread), requestId: "voice:\(UUID().uuidString)")
        } catch {
            lastError = error.localizedDescription
            return
        }
        // One turn is one message.
        close()
    }

    /// Every tenth of a second: Parakeet's passes, the countdown and the spoken commands.
    private func tick() {
        guard listening, !committing else { return }
        if engine == .parakeet { refreshIfDue() }
        guard mode == .auto, !text.isEmpty, detector.ended(text, at: now) else {
            sendsAt = nil
            return
        }
        switch VoiceCommand.parse(text).command {
        case .send:
            Task { await commitAndSend() }
        case .clear:
            tone(.cleared)
            clearTurn()
        case nil:
            if sendsAt == nil { sendsAt = .now.addingTimeInterval(Self.countdown) }
            if let sendsAt, sendsAt <= .now { Task { await commitAndSend() } }
        }
    }

    private func show(_ words: String, at time: Double) {
        // The same text again (Parakeet's next pass) isn't the user talking: the countdown goes on.
        guard words != text else { return }
        text = words
        detector.heard(text, at: time)
        if detector.words > 0 { sendsAt = nil }
    }

    // MARK: Apple

    private func heard(_ piece: SpeechTranscriber.Result) {
        // Results that end before this turn started belong to the one already sent.
        guard piece.range.end.seconds > turnStart + 0.05 else { return }
        let words = String(piece.text.characters)
        if piece.isFinal {
            finalized += words
            volatile = ""
        } else {
            volatile = words
        }
        show((finalized + volatile).trimmingCharacters(in: .whitespaces), at: now)
    }

    private func openApple() async throws {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
            .flatMap { $0.language.languageCode == .english ? $0 : nil } ?? Locale(identifier: "en-US")
        // Not `.fastResults`: it trades accuracy for speed.
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        try await SpeechModel.install(transcriber)
        // Kept loaded between turns and threads, so listening starts at once.
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        self.analyzer = analyzer
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriberError("On-device speech has no audio format for this iPhone.")
        }
        self.format = format
        sampleRate = format.sampleRate
        try await analyzer.prepareToAnalyze(in: format)
        results = Task { [weak self] in
            do {
                for try await result in transcriber.results { self?.heard(result) }
            } catch {
                self?.log.error("recognizer ended: \(error)")
            }
        }
    }

    // MARK: Parakeet

    private func openParakeet() async {
        format = Self.parakeetFormat
        sampleRate = Parakeet.sampleRate
        guard !(await Parakeet.shared.isLoaded) else { return }
        loadingModel = true
        Task { [weak self] in
            do {
                try await Parakeet.shared.load()
            } catch {
                self?.log.error("parakeet failed to load: \(error)")
                self?.fail(error)
            }
            self?.loadingModel = false
        }
    }

    /// This turn's samples, up to audio time `end`.
    private func samples(through end: Double) -> [Float] {
        let from = Int(max(0, Int64(turnStart * sampleRate) - audioStart))
        let to = Int(min(max(0, Int64(end * sampleRate) - audioStart), Int64(audio.count)))
        return from < to ? Array(audio[from..<to]) : []
    }

    /// Parakeet has no live results: the turn so far is transcribed again every second or so, and as soon as the user
    /// pauses, so the text is current before a pause ends the turn.
    private func refreshIfDue() {
        guard refreshing == nil, now > turnStart + 0.5 else { return }
        let spoke = detector.lastVoice > refreshedThrough
        let paused = spoke && now - detector.lastVoice >= 0.3
        // Long turns take longer to transcribe again: don't run back to back. Until the first words, keep trying even
        // if the microphone seems quiet.
        let due = now - refreshedThrough >= max(1.0, refreshCost * 3)
        guard paused || (due && (spoke || text.isEmpty)) else { return }
        let through = now
        let turn = turn
        let samples = samples(through: through)
        refreshing = Task { [weak self] in
            let started = Date.now
            let words: String?
            do {
                words = try await Parakeet.shared.transcribe(samples)
            } catch {
                self?.log.error("parakeet: \(error)")
                words = nil
            }
            guard let self else { return }
            self.refreshing = nil
            guard self.turn == turn, self.listening else { return }
            self.refreshCost = Date.now.timeIntervalSince(started)
            self.refreshedThrough = through
            if let words { self.show(words, at: through) }
        }
    }

    // MARK: Audio

    private func open(_ dictation: Dictation) async {
        state = .preparing
        engine = dictation == .parakeet && Parakeet.isBundled ? .parakeet : .apple
        do {
            guard await AVAudioApplication.requestRecordPermission() else {
                throw TranscriberError("Mycroft needs the microphone. Allow it in Settings → Mycroft.")
            }
            framesFed = 0
            audio = []
            audioStart = 0
            refreshCost = 0
            collectsSamples = engine == .parakeet
            let stream: AsyncStream<AnalyzerInput>?
            switch engine {
            case .apple:
                try await openApple()
                let (sequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
                input = continuation
                stream = sequence
            case .parakeet:
                await openParakeet()
                stream = nil
            }
            try startAudio()
            if let analyzer, let stream { try await analyzer.start(inputSequence: stream) }
            clearTurn()
            guard state == .preparing else { return }
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
        let message = (error as NSError).domain == "SFSpeechErrorDomain" && (error as NSError).code == 4
            ? "On-device speech isn't available here (the Simulator has no speech models)."
            : error.localizedDescription
        state = .failed(message)
        teardown()
    }

    private func close() {
        guard state != .off else { return }
        teardown()
        state = .off
        level = 0
        sendsAt = nil
    }

    private func teardown() {
        ticker?.cancel()
        ticker = nil
        refreshing?.cancel()
        refreshing = nil
        engineIO.inputNode.removeTap(onBus: 0)
        engineIO.stop()
        input?.finish()
        input = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        results?.cancel()
        results = nil
        audio = []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startAudio() throws {
        let session = AVAudioSession.sharedInstance()
        // No voice processing: it is made for calls and smears speech for a recognizer. AirPods that can record at full
        // bandwidth are used (never their narrow-band call microphone); otherwise the iPhone's own microphone, with
        // the least processing iOS offers.
        try session.setCategory(
            .playAndRecord, mode: .default, options: [.bluetoothHighQualityRecording, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setActive(true)
        let fullBandwidth = session.currentRoute.inputs.contains { $0.bluetoothMicrophoneExtension?.highQualityRecording.isEnabled == true }
        if !fullBandwidth { try session.setMode(.measurement) }
        let node = engineIO.inputNode
        let inputFormat = node.outputFormat(forBus: 0)
        converter = format.flatMap { $0 == inputFormat ? nil : AVAudioConverter(from: inputFormat, to: $0) }
        if player.engine == nil {
            engineIO.attach(player)
            engineIO.connect(player, to: engineIO.mainMixerNode, format: Self.playFormat)
        }
        node.installTap(onBus: 0, bufferSize: 2048, format: inputFormat, block: AudioTap.block { [weak self] buffer in
            self?.captured(buffer)
        })
        engineIO.prepare()
        try engineIO.start()
        player.play()
    }

    nonisolated private func captured(_ buffer: AVAudioPCMBuffer) {
        let rms = Self.rms(buffer)
        var output = buffer
        if let converter, let format {
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
        if collectsSamples {
            guard let channel = output.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            Task { @MainActor in
                guard self.listening || self.state == .preparing else { return }
                self.audio += samples
                self.heardAudio(frames: frames, rms: rms)
            }
        } else {
            let analyzerInput = AnalyzerInput(buffer: output)
            Task { @MainActor in
                guard self.listening else { return }
                self.input?.yield(analyzerInput)
                self.heardAudio(frames: frames, rms: rms)
            }
        }
    }

    private func heardAudio(frames: Int64, rms: Double) {
        framesFed += frames
        detector.level(rms, at: now)
        level = level * 0.6 + min(1, rms * 8) * 0.4
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
        return Double(sqrt(sum / Float(buffer.frameLength)))
    }

    // MARK: Tones

    enum Tone {
        case listening, sent, cleared

        var notes: [(frequency: Double, seconds: Double)] {
            switch self {
            case .listening: [(880, 0.06)]
            case .sent: [(660, 0.05), (990, 0.07)]
            case .cleared: [(520, 0.08)]
            }
        }
    }

    /// A short, quiet cue, so the screen needn't be watched.
    func tone(_ tone: Tone) {
        guard engineIO.isRunning else { return }
        let format = Self.playFormat
        let gap = Int(format.sampleRate * 0.03)
        let frames = tone.notes.reduce(0) { $0 + Int(format.sampleRate * $1.seconds) + gap }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
            let samples = buffer.floatChannelData?[0]
        else { return }
        var index = 0
        for note in tone.notes {
            let count = Int(format.sampleRate * note.seconds)
            for frame in 0..<count {
                // A raised-cosine envelope: no clicks at either end.
                let envelope = 0.5 - 0.5 * cos(2 * Double.pi * Double(frame) / Double(count))
                samples[index] = Float(sin(2 * Double.pi * note.frequency * Double(frame) / format.sampleRate) * envelope * 0.12)
                index += 1
            }
            for _ in 0..<gap { samples[index] = 0; index += 1 }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        player.scheduleBuffer(buffer)
    }
}
