import AVFoundation
import Foundation
import Observation
import Speech
import os

/// Dictation in every thread, on the iPhone itself (docs/decisions/0010-voice-in-every-thread.md, 0011, 0014).
///
/// One listener, for one thread's composer at a time, with the model chosen in Settings ([`Dictation`]):
/// - **Fluid Speech Mini** (bundled): the words so far are transcribed again every second and at every pause, so the
///   text arrives in short steps, and the final text is always one pass over everything said.
/// - **Apple** (SpeechTranscriber, English): words appear as they are spoken.
///
/// The user starts and stops it; nothing is sent on a pause. The composer holds the mic (release sends) or taps it
/// (tap again, or send). `stop()` hands back the words and the page sends them like typed text.
///
/// Listening runs here, not in the web page, so it carries on with the screen locked (the app has background audio).
/// The page shows `snapshot()` and drives it with the methods below.
@Observable
final class Listener {
    enum State: Equatable {
        case off, preparing, on
        case failed(String)
    }

    private(set) var state: State = .off
    /// Whose composer is listening: a thread id, or a new thread's draft id.
    private(set) var owner: String?
    /// The model this session listens with.
    private(set) var engine: Dictation = .apple
    /// What the user has said.
    private(set) var text = ""
    /// Typed text the words go after.
    private(set) var prefix = ""
    /// Microphone level 0…1.
    private(set) var level: Double = 0
    /// When listening started, for the timer.
    private(set) var startedAt: Date?
    private(set) var lastError: String?

    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var activity = VoiceActivity()
    /// Audio time where the words start: earlier results were cleared.
    @ObservationIgnored private var turnStart: Double = 0
    /// Counts clears, so a transcription that finishes after its words were cleared is dropped.
    @ObservationIgnored private var turn = 0
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

    // Fluid Speech Mini
    /// The samples from `audioStart` (a frame index) on.
    @ObservationIgnored private var audio: [Float] = []
    @ObservationIgnored private var audioStart: Int64 = 0
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    /// Audio time the shown text covers, and what the last pass took.
    @ObservationIgnored private var refreshedThrough: Double = 0
    @ObservationIgnored private var refreshCost: Double = 0

    /// The format the tone is played in.
    nonisolated static let playFormat = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
    nonisolated static let modelFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: FluidSpeech.sampleRate, channels: 1, interleaved: false)!

    /// Audio seconds heard: the clock the words are measured on.
    private var now: Double { Double(framesFed) / sampleRate }
    private var listening: Bool { state == .on }

    // MARK: Control

    /// Loads Fluid Speech Mini when the app starts and when it is chosen, so dictation starts at once; frees it when
    /// Apple's model is chosen instead. A load takes well under a second, except the first after an install or update
    /// (about 10 s on an iPhone 17 Pro Max, while Core ML prepares it for the Neural Engine).
    static func warm(_ app: AppModel) {
        guard FluidSpeech.isBundled else { return }
        Task {
            guard app.dictation == .fluid else {
                await FluidSpeech.shared.unload()
                app.fluidReady = false
                return
            }
            let log = Logger(subsystem: "dev.mycroft", category: "listener")
            let started = Date.now
            do {
                try await FluidSpeech.shared.load()
                app.fluidReady = app.dictation == .fluid
                log.notice("fluid speech loaded in \(Date.now.timeIntervalSince(started), format: .fixed(precision: 2)) s")
            } catch {
                log.error("fluid speech failed to load: \(error)")
            }
        }
    }

    /// Listens for `owner`'s composer, after the typed `prefix`.
    func start(_ owner: String, prefix: String = "", dictation: Dictation) async {
        if self.owner != owner {
            self.owner = owner
            clearWords()
        }
        self.prefix = prefix
        lastError = nil
        if state == .on { return }
        startedAt = .now
        await open(dictation)
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

    /// The thread's screen went away, or the app was closed.
    func shutDown() {
        close()
        owner = nil
    }

    /// What the page shows.
    func snapshot() -> [String: Any] {
        var state: [String: Any] = [
            "owner": owner ?? NSNull(), "engine": engine.rawValue, "text": text,
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
        finalized = ""
        volatile = ""
        text = ""
        turnStart = start
        turn += 1
        refreshedThrough = start
        activity.reset(at: start)
        let drop = Int(min(max(0, Int64(start * sampleRate) - audioStart), Int64(audio.count)))
        audio.removeFirst(drop)
        audioStart += Int64(drop)
    }

    /// Everything heard, finalized.
    private func finish() async -> String {
        guard listening else { return text }
        let cut = now
        let turn = turn
        switch engine {
        case .apple:
            try? await analyzer?.finalize(through: CMTime(seconds: cut, preferredTimescale: 48_000))
            // The final results for everything through the cut arrive right after.
            for _ in 0..<10 where !volatile.isEmpty { try? await Task.sleep(for: .milliseconds(30)) }
        case .fluid:
            // The shown text already covers it all unless the user was still talking.
            if refreshedThrough < activity.lastVoice + 0.2 {
                do {
                    text = try await FluidSpeech.shared.transcribe(samples(through: cut))
                } catch {
                    lastError = error.localizedDescription
                }
            }
        }
        // Cleared while it finished.
        return self.turn == turn ? text : ""
    }

    /// Every tenth of a second: Fluid Speech Mini's passes.
    private func tick() {
        guard listening, engine == .fluid else { return }
        refreshIfDue()
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
        text = (finalized + volatile).trimmingCharacters(in: .whitespaces)
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

    // MARK: Fluid Speech Mini

    private func openFluid() {
        format = Self.modelFormat
        sampleRate = FluidSpeech.sampleRate
    }

    /// This turn's samples, up to audio time `end`.
    private func samples(through end: Double) -> [Float] {
        let from = Int(max(0, Int64(turnStart * sampleRate) - audioStart))
        let to = Int(min(max(0, Int64(end * sampleRate) - audioStart), Int64(audio.count)))
        return from < to ? Array(audio[from..<to]) : []
    }

    /// Fluid Speech Mini has no live results: the turn so far is transcribed again every second or so, and as soon as
    /// the user pauses, so the text is current before a pause ends the turn.
    private func refreshIfDue() {
        guard refreshing == nil, now > turnStart + 0.5 else { return }
        let spoke = activity.lastVoice > refreshedThrough
        let paused = spoke && now - activity.lastVoice >= 0.3
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

    private func open(_ dictation: Dictation) async {
        state = .preparing
        // Fluid Speech Mini once it has loaded (it loads at launch and when chosen); until then Apple's model, so dictation never
        // waits for it.
        let fluidLoaded = await FluidSpeech.shared.isLoaded
        engine = dictation == .fluid && FluidSpeech.isBundled && fluidLoaded ? .fluid : .apple
        do {
            guard await AVAudioApplication.requestRecordPermission() else {
                throw TranscriberError("Mycroft needs the microphone. Allow it in Settings → Mycroft.")
            }
            framesFed = 0
            audio = []
            audioStart = 0
            refreshCost = 0
            collectsSamples = engine == .fluid
            let stream: AsyncStream<AnalyzerInput>?
            switch engine {
            case .apple:
                try await openApple()
                let (sequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
                input = continuation
                stream = sequence
            case .fluid:
                openFluid()
                stream = nil
            }
            try startAudio()
            if let analyzer, let stream { try await analyzer.start(inputSequence: stream) }
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
        startedAt = nil
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
        activity.level(rms, at: now)
        level = level * 0.6 + min(1, rms * 8) * 0.4
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
        return Double(sqrt(sum / Float(buffer.frameLength)))
    }

    // MARK: Tone

    /// A short, quiet cue that the microphone is on, so the screen needn't be watched.
    private func tone() {
        guard engineIO.isRunning else { return }
        let format = Self.playFormat
        let count = Int(format.sampleRate * 0.06)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
            let samples = buffer.floatChannelData?[0]
        else { return }
        for frame in 0..<count {
            // A raised-cosine envelope: no clicks at either end.
            let envelope = 0.5 - 0.5 * cos(2 * Double.pi * Double(frame) / Double(count))
            samples[frame] = Float(sin(2 * Double.pi * 880 * Double(frame) / format.sampleRate) * envelope * 0.12)
        }
        buffer.frameLength = AVAudioFrameCount(count)
        player.scheduleBuffer(buffer)
    }
}
