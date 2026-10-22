import CoreML
import FluidAudio
import Foundation

/// Fluid Speech Mini (CC-BY-4.0, FluidVoice), the one dictation model (docs/decisions/0017): English, built on NVIDIA's Parakeet TDT 0.6B v3 and Moondream's
/// Parakeet Ultra, a drop-in Parakeet v3 Core ML package run by FluidAudio (Apache-2.0) on the Neural Engine. The model
/// (~240 MB) is in the app bundle (ios/scripts/fetch-fluid-speech.sh); it loads when the app starts and stays loaded.
actor FluidSpeech {
    static let shared = FluidSpeech()

    /// Audio it takes: 16 kHz mono.
    nonisolated static let sampleRate = 16_000.0
    nonisolated static let directory = Bundle.main.url(forResource: "FluidSpeech", withExtension: nil)
    nonisolated static var isBundled: Bool { directory != nil }

    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?

    var isLoaded: Bool { manager != nil }

    /// Loads the model. The first load after an install takes longer, while Core ML prepares it for the Neural Engine.
    @discardableResult
    func load() async throws -> AsrManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        guard let directory = Self.directory else {
            throw VoiceError("This build of Mycroft doesn't include Fluid Speech Mini (run ios/scripts/fetch-fluid-speech.sh).")
        }
        let task = Task {
            let models = try await AsrModels.loadLocal(from: directory, version: .v3)
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
