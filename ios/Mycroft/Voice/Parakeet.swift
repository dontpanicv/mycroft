import CoreML
import FluidAudio
import Foundation

/// Which model turns speech into text. Chosen in Settings, kept in UserDefaults.
nonisolated enum Dictation: String, Sendable {
    /// NVIDIA's Parakeet TDT 0.6B v3, bundled in the app: clearly better with accents and casual speech.
    case parakeet
    /// Apple's SpeechTranscriber: words appear as they are spoken.
    case apple

    static let key = "mycroft.dictation"

    /// The saved choice, or Parakeet when the app has it.
    static var saved: Dictation {
        UserDefaults.standard.string(forKey: key).flatMap(Dictation.init) ?? (Parakeet.isBundled ? .parakeet : .apple)
    }
}

/// Parakeet TDT 0.6B v3 (CC-BY-4.0) through FluidAudio (Apache-2.0), on the Neural Engine. The model (~460 MB) is in
/// the app bundle (ios/scripts/fetch-parakeet.sh); it loads once, on first use, and stays loaded.
actor Parakeet {
    static let shared = Parakeet()

    /// Audio it takes: 16 kHz mono.
    nonisolated static let sampleRate = 16_000.0
    nonisolated static let directory = Bundle.main.url(forResource: "Parakeet", withExtension: nil)
    nonisolated static var isBundled: Bool { directory != nil }

    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?

    var isLoaded: Bool { manager != nil }

    /// Loads the model; the first load on a device takes a few seconds while CoreML prepares it for the Neural Engine.
    @discardableResult
    func load() async throws -> AsrManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        guard let directory = Self.directory else {
            throw TranscriberError("This build of Mycroft doesn't include Parakeet (run ios/scripts/fetch-parakeet.sh).")
        }
        let task = Task {
            let models = try AsrModels.loadLocal(from: directory, version: .v3)
            return AsrManager(models: models)
        }
        loading = task
        defer { loading = nil }
        let manager = try await task.value
        self.manager = manager
        return manager
    }

    func unload() {
        manager = nil
    }

    /// The text of 16 kHz mono samples, with punctuation and capitals.
    func transcribe(_ samples: [Float]) async throws -> String {
        // Under a quarter second is nothing to transcribe (and the model wants at least a second, padded).
        guard samples.count > Int(Self.sampleRate / 4) else { return "" }
        let manager = try await load()
        let padded = samples.count < Int(Self.sampleRate) ? samples + [Float](repeating: 0, count: Int(Self.sampleRate) - samples.count) : samples
        var state = try TdtDecoderState()
        return try await manager.transcribe(padded, decoderState: &state).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
