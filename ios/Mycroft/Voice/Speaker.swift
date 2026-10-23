import AVFoundation
import FluidAudio
import Foundation
import Observation
import os

/// Mycroft's voice in a conversation (``VoiceChat``): Gradium's Phonon 31m (Apache-2.0), converted to Core ML by
/// FluidInference and run by FluidAudio, the model on the Neural Engine and its audio decoder on the CPU. It is bundled
/// (ios/scripts/fetch-phonon.sh, ~150 MB) and loads when a conversation starts.
///
/// Sentences are made one after another as they arrive. Each streams in 80 ms frames that play as soon as they exist,
/// so the first words play while the rest of the sentence, and of the answer, is still being made. In a conversation
/// the audio plays through the listener's engine: echo cancellation needs what the speaker plays on the engine that
/// records.
@Observable
final class Speaker {
    static let shared = Speaker()

    struct Voice: Sendable {
        let id: String
        let name: String
        let accent: String
    }

    /// The English voices offered in Settings (the bundle has all of Phonon's English ones).
    static let voices: [Voice] = [
        Voice(id: "en_us_Easton", name: "Easton", accent: "American"),
        Voice(id: "en_us_Zoey", name: "Zoey", accent: "American"),
        Voice(id: "en_us_Juniper", name: "Juniper", accent: "American"),
        Voice(id: "en_us_Miles", name: "Miles", accent: "American"),
        Voice(id: "en_gb_Maeve", name: "Maeve", accent: "British"),
        Voice(id: "en_gb_Hugh", name: "Hugh", accent: "British"),
    ]
    static let key = "mycroft.voice"

    nonisolated static let directory = Bundle.main.url(forResource: "Phonon", withExtension: nil)
    nonisolated static var isBundled: Bool { directory != nil }
    nonisolated static let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

    /// The voice Mycroft speaks with, chosen in Settings.
    var voice = UserDefaults.standard.string(forKey: key).flatMap { id in voices.first { $0.id == id }?.id } ?? "en_us_Easton" {
        didSet { UserDefaults.standard.set(voice, forKey: Self.key) }
    }
    /// The model is loaded: speech starts at once.
    private(set) var ready = false
    /// What has started playing since the last ``stop()``, to tell Mycroft's own voice from the user's.
    private(set) var said = ""
    /// The sentence playing now.
    private(set) var current: String?
    /// Output level 0…1 of what plays now.
    private(set) var level: Double = 0
    /// Sentences waiting, being made, or playing.
    var isSpeaking: Bool { !queue.isEmpty || making || played < scheduled }

    /// The node the voice plays on, in the engine it is connected to.
    @ObservationIgnored let player = AVAudioPlayerNode()

    private var queue: [String] = []
    private var making = false
    /// The sentence being made whose audio hasn't been scheduled yet.
    @ObservationIgnored private var unstarted: String?
    private var scheduled = 0
    private var played = 0
    /// The sentence and level of buffers not yet playing, by their number.
    @ObservationIgnored private var starts: [Int: String] = [:]
    @ObservationIgnored private var levels: [Int: Double] = [:]
    /// Counts stops: audio scheduled before one finishes into nothing.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var manager: PocketTtsSmallManager?
    @ObservationIgnored private var loading: Task<PocketTtsSmallManager, Error>?
    /// An engine of its own, for a sample in Settings outside a conversation.
    @ObservationIgnored private var ownEngine: AVAudioEngine?
    @ObservationIgnored private let log = Logger(subsystem: "dev.mycroft", category: "speaker")

    // MARK: Model

    /// Loads Phonon and makes a first sentence, so the Neural Engine is warm for the first real one. A load takes a
    /// moment, except the first after an install, while Core ML prepares the model for this iPhone.
    @discardableResult
    func load() async throws -> PocketTtsSmallManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        guard let directory = Self.directory else {
            throw Failure("This build of Mycroft doesn't include Phonon (run ios/scripts/fetch-phonon.sh).")
        }
        let voice = voice
        let task = Task {
            let started = Date.now
            let manager = PocketTtsSmallManager(model: .phonon31m)
            try await manager.load(from: directory)
            _ = try await manager.synthesizeSamples(text: "Okay.", voice: voice, deEss: false)
            Logger(subsystem: "dev.mycroft", category: "speaker")
                .notice("phonon loaded in \(Date.now.timeIntervalSince(started), format: .fixed(precision: 2)) s")
            return manager
        }
        loading = task
        defer { loading = nil }
        let manager = try await task.value
        self.manager = manager
        ready = true
        return manager
    }

    // MARK: Speaking

    /// Plays through `engine` from now on (the listener's, in a conversation). Call before the engine starts.
    func connect(to engine: AVAudioEngine) {
        if let current = player.engine {
            guard current !== engine else { return }
            current.detach(player)
        }
        if let ownEngine, ownEngine !== engine { ownEngine.stop() }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.format)
    }

    /// Says `sentence` after what is already queued.
    func say(_ sentence: String) {
        queue.append(sentence)
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.work()
            self?.worker = nil
        }
    }

    /// Stops at once: what plays, what is being made and what waits.
    func stop() {
        generation += 1
        worker?.cancel()
        worker = nil
        queue = []
        making = false
        unstarted = nil
        scheduled = 0
        played = 0
        starts = [:]
        levels = [:]
        current = nil
        level = 0
        said = ""
        player.stop()
        if player.engine?.isRunning == true { player.play() }
    }

    /// Stops like ``stop()`` and hands back what wasn't fully said, in order: the sentence playing (from its start) and
    /// the ones after it. For carrying on when the audio has to restart (headphones came or went).
    func halt() -> [String] {
        var rest = [current].compactMap { $0 } + starts.sorted { $0.key < $1.key }.map(\.value)
        if let unstarted { rest.append(unstarted) }
        rest += queue
        stop()
        return rest
    }

    /// Says a sample in `voice`, outside a conversation (Settings).
    func sample(_ voice: String) async throws {
        self.voice = voice
        stop()
        let engine = ownEngine ?? AVAudioEngine()
        ownEngine = engine
        connect(to: engine)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        player.play()
        let name = Self.voices.first { $0.id == voice }?.name ?? "Mycroft"
        say("Hi, I'm Mycroft, speaking as \(name). This is how I'll sound when we talk.")
    }

    private func work() async {
        let generation = generation
        while !Task.isCancelled, generation == self.generation, !queue.isEmpty {
            let sentence = queue.removeFirst()
            making = true
            unstarted = sentence
            do {
                let manager = try await load()
                var first = true
                for try await frame in try await manager.synthesizeStreaming(text: sentence, voice: voice) {
                    guard !Task.isCancelled, generation == self.generation else { break }
                    schedule(frame.samples, starting: first ? sentence : nil)
                    if first { unstarted = nil }
                    first = false
                }
            } catch is CancellationError {
            } catch {
                log.error("phonon failed on \"\(sentence)\": \(error)")
            }
            if generation == self.generation { making = false }
        }
    }

    private func schedule(_ samples: [Float], starting sentence: String?) {
        guard player.engine != nil, !samples.isEmpty,
            let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        var sum: Float = 0
        for (index, sample) in samples.enumerated() {
            channel[index] = sample
            sum += sample * sample
        }
        let rms = min(1, Double((sum / Float(samples.count)).squareRoot()) * 6)
        let number = scheduled
        if played == scheduled {
            // Nothing is playing: this starts now.
            if let sentence { begin(sentence) }
            level = rms
        } else {
            if let sentence { starts[number] = sentence }
            levels[number] = rms
        }
        scheduled += 1
        let generation = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack, completionHandler: AudioTap.played { [weak self] in
            Task { @MainActor in self?.finished(number, generation: generation) }
        })
        if !player.isPlaying, player.engine?.isRunning == true { player.play() }
    }

    /// Buffer `number` has played: the next one starts.
    private func finished(_ number: Int, generation: Int) {
        guard generation == self.generation else { return }
        played = number + 1
        if let sentence = starts.removeValue(forKey: played) { begin(sentence) }
        level = levels.removeValue(forKey: played) ?? 0
        if played == scheduled, queue.isEmpty, !making { current = nil }
    }

    private func begin(_ sentence: String) {
        current = sentence
        // The last few sentences are enough to recognize an echo.
        said = String((said.isEmpty ? sentence : said + " " + sentence).suffix(400))
    }
}
