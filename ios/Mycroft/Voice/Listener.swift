import AVFoundation
import Foundation
import Observation
import PiDurableKit
import Speech
import os

/// Voice in every thread, on the iPhone itself (docs/decisions/0010-voice-in-every-thread.md).
///
/// One warm recognizer (Apple's SpeechTranscriber, English) listens for one thread at a time:
/// - **hold:** the screen holds the mic button; releasing sends.
/// - **auto:** a pause ends the turn ([`TurnDetector`]); after a short countdown the turn is sent. Talking again
///   cancels the countdown; "send it" sends at once, "scratch that" throws the turn away.
/// - **read aloud:** after sending, the answer is read with the best installed English voice, and listening goes on.
///   Talking while it reads stops the reading.
///
/// The loop runs here, not in the web page, so it carries on with the screen locked (the app has background audio).
/// The page shows `snapshot()` and steers with the methods below. Audio runs through one engine with voice processing
/// (echo cancellation), and the reading plays through that engine too, so the microphone doesn't hear it.
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
    private(set) var readAloud = false
    /// What the user is saying in this turn.
    private(set) var text = ""
    /// Typed text the turn goes after.
    private(set) var prefix = ""
    /// Microphone level 0…1.
    private(set) var level: Double = 0
    /// When the pause-to-send fires.
    private(set) var sendsAt: Date?
    private(set) var speaking = false
    /// Mycroft is working on what was sent, and the answer will be read.
    private(set) var awaitingAnswer = false
    /// Counts sends, so the page clears its draft once per send.
    private(set) var sent = 0
    private(set) var lastError: String?

    /// How long the countdown runs between the pause and sending.
    static let countdown: TimeInterval = 1.0

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var input: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var results: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var answer: Task<Void, Never>?
    @ObservationIgnored private var finalized = ""
    @ObservationIgnored private var volatile = ""
    @ObservationIgnored private var detector = TurnDetector()
    /// Audio time where this turn starts: earlier results belong to the previous one.
    @ObservationIgnored private var turnStart: Double = 0
    @ObservationIgnored private var framesFed: Int64 = 0
    @ObservationIgnored private var sampleRate: Double = 16_000
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored nonisolated(unsafe) private var converter: AVAudioConverter?
    @ObservationIgnored nonisolated(unsafe) private var analyzerFormat: AVAudioFormat?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var reading: Reading?
    @ObservationIgnored private let log = Logger(subsystem: "dev.mycroft", category: "listener")

    /// The format the reading and the tones are played in.
    nonisolated static let playFormat = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!

    /// Audio seconds fed to the recognizer: the clock the turn is measured on.
    private var now: Double { Double(framesFed) / sampleRate }
    private var listening: Bool { state == .on }

    // MARK: Control

    /// Listens for `thread`. A different thread's turn is dropped; the same thread's goes on.
    func start(_ thread: ThreadMeta, mode: Mode, prefix: String = "", app: AppModel) async {
        self.app = app
        if self.thread?.id != thread.id {
            self.thread = thread
            readAloud = false
            clearTurn()
        }
        self.mode = mode
        self.prefix = prefix
        sendsAt = nil
        lastError = nil
        if state == .on { return }
        await open()
        if state == .on { tone(.listening) }
    }

    /// Hold became hands-free (the button was slid up), or the reverse.
    func setMode(_ mode: Mode) {
        self.mode = mode
        sendsAt = nil
    }

    /// Reads answers aloud and keeps listening between turns.
    func setReadAloud(_ on: Bool, thread: ThreadMeta, app: AppModel) async {
        if on {
            await start(thread, mode: .auto, prefix: prefix, app: app)
            readAloud = state == .on
        } else if self.thread?.id == thread.id {
            readAloud = false
            stopReading()
        }
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
        readAloud = false
        close()
        return kept
    }

    /// Throws the turn away and stops, unless reading aloud keeps the microphone on.
    func cancel() {
        clearTurn()
        if !readAloud { close() }
    }

    /// The thread's screen went away, or the app was closed.
    func shutDown() {
        readAloud = false
        answer?.cancel()
        answer = nil
        awaitingAnswer = false
        stopReading()
        close()
        thread = nil
    }

    /// What the page shows.
    func snapshot() -> [String: Any] {
        var state: [String: Any] = [
            "thread": thread?.id.rawValue ?? NSNull(), "mode": mode.rawValue, "readAloud": readAloud, "text": text,
            "prefix": prefix, "level": (level * 100).rounded() / 100, "speaking": speaking,
            "awaitingAnswer": awaitingAnswer, "sent": sent, "error": lastError ?? NSNull(),
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

    private func clearTurn() {
        finalized = ""
        volatile = ""
        text = ""
        sendsAt = nil
        turnStart = now
        detector.reset(at: now)
    }

    /// Finalizes everything heard so far and returns this turn's words; the next turn starts here.
    private func commit() async -> String {
        guard let analyzer, listening else {
            let words = text
            clearTurn()
            return VoiceCommand.parse(words).text
        }
        let cut = now
        try? await analyzer.finalize(through: CMTime(seconds: cut, preferredTimescale: 48_000))
        // The final results for everything through the cut arrive right after.
        for _ in 0..<10 where !volatile.isEmpty { try? await Task.sleep(for: .milliseconds(30)) }
        let words = VoiceCommand.parse(text).text
        clearTurn()
        turnStart = cut
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
        // Without reading aloud, one turn is one message; with it, listening goes on.
        if readAloud { awaitAnswer(thread) } else { close() }
    }

    /// Reads the thread's answer once its run ends, then listens on.
    private func awaitAnswer(_ thread: ThreadMeta) {
        answer?.cancel()
        awaitingAnswer = true
        answer = Task { [weak self] in
            guard let app = self?.app else { return }
            // The run may take a moment to show as busy.
            for _ in 0..<20 where !(await app.isBusy(thread)) { try? await Task.sleep(for: .milliseconds(150)) }
            while await app.isBusy(thread) {
                try? await Task.sleep(for: .milliseconds(400))
                if Task.isCancelled { return }
            }
            guard let self, !Task.isCancelled, self.readAloud else { return }
            self.awaitingAnswer = false
            guard let answer = await app.lastAnswer(thread), !answer.isEmpty else { return }
            self.tone(.ready)
            await self.read(answer)
        }
    }

    /// Every tenth of a second: the countdown and the spoken commands.
    private func tick() {
        guard listening, mode == .auto, !text.isEmpty else {
            sendsAt = nil
            return
        }
        guard detector.ended(text, at: now) else {
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
        detector.heard(text, at: now)
        if detector.words > 0 {
            sendsAt = nil
            // Talking over the reading stops it.
            if speaking { stopReading() }
        }
    }

    // MARK: Recognizer and audio

    private func open() async {
        state = .preparing
        do {
            guard await AVAudioApplication.requestRecordPermission() else {
                throw TranscriberError("Mycroft needs the microphone. Allow it in Settings → Mycroft.")
            }
            let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
                .flatMap { $0.language.languageCode == .english ? $0 : nil } ?? Locale(identifier: "en-US")
            let transcriber = SpeechTranscriber(
                locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [])
            try await SpeechModel.install(transcriber)
            // Kept loaded between turns and threads, so listening starts at once.
            let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
            self.analyzer = analyzer
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw TranscriberError("On-device speech has no audio format for this iPhone.")
            }
            analyzerFormat = format
            sampleRate = format.sampleRate
            try await analyzer.prepareToAnalyze(in: format)
            framesFed = 0
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            input = continuation
            results = Task { [weak self] in
                do {
                    for try await result in transcriber.results { self?.heard(result) }
                } catch {
                    self?.log.error("recognizer ended: \(error)")
                }
            }
            try startAudio()
            try await analyzer.start(inputSequence: stream)
            clearTurn()
            state = .on
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    self?.tick()
                }
            }
        } catch {
            log.error("listener failed: \(error)")
            let message = (error as NSError).domain == "SFSpeechErrorDomain" && (error as NSError).code == 4
                ? "On-device speech isn't available here (the Simulator has no speech models)."
                : error.localizedDescription
            state = .failed(message)
            teardown()
        }
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
        stopReading()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        input?.finish()
        input = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        results?.cancel()
        results = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try session.setActive(true)
        let node = engine.inputNode
        // Echo cancellation: the microphone doesn't hear the reading, so talking over it can stop it.
        try node.setVoiceProcessingEnabled(true)
        let inputFormat = node.outputFormat(forBus: 0)
        converter = analyzerFormat.flatMap { $0 == inputFormat ? nil : AVAudioConverter(from: inputFormat, to: $0) }
        if player.engine == nil {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: Self.playFormat)
        }
        node.installTap(onBus: 0, bufferSize: 2048, format: inputFormat, block: AudioTap.block { [weak self] buffer in
            self?.captured(buffer)
        })
        engine.prepare()
        try engine.start()
        player.play()
    }

    nonisolated private func captured(_ buffer: AVAudioPCMBuffer) {
        let rms = Self.rms(buffer)
        var output = buffer
        if let converter, let format = analyzerFormat {
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
        let analyzerInput = AnalyzerInput(buffer: output)
        let frames = Int64(output.frameLength)
        Task { @MainActor in
            guard self.listening else { return }
            self.input?.yield(analyzerInput)
            self.framesFed += frames
            self.detector.level(rms, at: self.now)
            self.level = self.level * 0.6 + min(1, rms * 8) * 0.4
        }
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
        return Double(sqrt(sum / Float(buffer.frameLength)))
    }

    // MARK: Reading aloud

    /// Reads `text` with the best installed English voice, through the engine (so the echo canceller knows it).
    /// Returns when it's done or interrupted.
    private func read(_ text: String) async {
        guard listening else { return }
        stopReading()
        let utterance = AVSpeechUtterance(string: Self.speakable(text))
        utterance.voice = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .max { ($0.quality.rawValue, $0.language == "en-US" ? 1 : 0) < ($1.quality.rawValue, $1.language == "en-US" ? 1 : 0) }
        let reading = Reading(player: player)
        self.reading = reading
        speaking = true
        await withCheckedContinuation { continuation in
            reading.onEnd = { continuation.resume() }
            synthesizer.write(utterance) { buffer in reading.schedule(buffer) }
        }
        if self.reading === reading { self.reading = nil }
        speaking = false
    }

    private func stopReading() {
        guard let reading else { return }
        self.reading = nil
        synthesizer.stopSpeaking(at: .immediate)
        reading.cancel()
        speaking = false
    }

    enum Tone {
        case listening, sent, ready, cleared

        var notes: [(frequency: Double, seconds: Double)] {
            switch self {
            case .listening: [(880, 0.06)]
            case .sent: [(660, 0.05), (990, 0.07)]
            case .ready: [(990, 0.05), (1320, 0.08)]
            case .cleared: [(520, 0.08)]
            }
        }
    }

    /// A short, quiet cue, so the screen needn't be watched.
    func tone(_ tone: Tone) {
        guard engine.isRunning, !speaking else { return }
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

    /// Markdown and code read badly aloud: keep prose, drop code blocks and symbols, cap the length.
    static func speakable(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " (code on screen) ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[*_`#>|]"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        return result.count > 700 ? String(result.prefix(700)) + "… The rest is on screen." : result
    }
}

/// One reading's buffers on their way to the player. The synthesizer's callback runs on its own queue.
nonisolated private final class Reading: @unchecked Sendable {
    private let lock = NSLock()
    private let player: AVAudioPlayerNode
    private var converters: [AVAudioFormat: AVAudioConverter] = [:]
    private var scheduled = 0
    private var played = 0
    private var written = false
    private var ended = false
    var onEnd: (() -> Void)?

    init(player: AVAudioPlayerNode) {
        self.player = player
    }

    func schedule(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !ended else { return }
        // An empty buffer marks the end of the utterance.
        guard pcm.frameLength > 0 else {
            written = true
            finishIfDone()
            return
        }
        guard let converted = convert(pcm) else { return }
        scheduled += 1
        player.scheduleBuffer(converted, completionCallbackType: .dataPlayedBack, completionHandler: AudioTap.played { [weak self] in
            self?.playedOne()
        })
    }

    func cancel() {
        lock.lock()
        let wasEnded = ended
        ended = true
        let end = onEnd
        onEnd = nil
        lock.unlock()
        player.stop()
        player.play()
        if !wasEnded { Task { @MainActor in end?() } }
    }

    private func playedOne() {
        lock.lock()
        defer { lock.unlock() }
        played += 1
        finishIfDone()
    }

    /// Called with the lock held.
    private func finishIfDone() {
        guard written, played >= scheduled, !ended else { return }
        ended = true
        let end = onEnd
        onEnd = nil
        Task { @MainActor in end?() }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let target = Listener.playFormat
        if buffer.format == target { return buffer }
        let converter = converters[buffer.format] ?? AVAudioConverter(from: buffer.format, to: target)
        guard let converter else { return nil }
        converters[buffer.format] = converter
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }
}
