import AVFoundation
import Foundation
import Observation
import Speech
import os

/// Speech to text on the iPhone itself, with Apple's SpeechAnalyzer and SpeechTranscriber. Nothing leaves the device.
///
/// `text` is the finalized transcript plus the current volatile guess, so the UI can show words as they are spoken.
@Observable
final class Transcriber {
    enum State: Equatable {
        case idle, preparing, listening
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var finalized = ""
    private(set) var volatile = ""
    /// Microphone level 0…1.
    private(set) var level: Double = 0
    /// When the last words were heard, for end-of-speech detection.
    private(set) var lastSpeech = Date.distantPast

    var text: String { (finalized + volatile).trimmingCharacters(in: .whitespaces) }

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var input: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var results: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var converter: AVAudioConverter?
    @ObservationIgnored nonisolated(unsafe) private var analyzerFormat: AVAudioFormat?
    @ObservationIgnored private let log = Logger(subsystem: "dev.mycroft", category: "transcriber")

    func start() async {
        guard state == .idle || isFailed else { return }
        state = .preparing
        finalized = ""
        volatile = ""
        do {
            guard await AVAudioApplication.requestRecordPermission() else {
                throw TranscriberError("Mycroft needs the microphone. Allow it in Settings → Mycroft.")
            }
            let model = await SpeechModel.make(locale: Locale.current, live: true)
            try await SpeechModel.install(model.module)
            let analyzer = SpeechAnalyzer(modules: [model.module])
            self.analyzer = analyzer
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [model.module])
            analyzerFormat = format
            try await analyzer.prepareToAnalyze(in: format)

            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            input = continuation
            results = Task { [weak self] in
                do {
                    for try await result in model.results {
                        guard let self else { return }
                        let words = result.text
                        if result.isFinal {
                            self.finalized += words
                            self.volatile = ""
                        } else {
                            self.volatile = words
                        }
                        if !words.trimmingCharacters(in: .whitespaces).isEmpty { self.lastSpeech = .now }
                    }
                } catch {
                    self?.log.error("transcription ended: \(error)")
                }
            }
            try startAudio()
            try await analyzer.start(inputSequence: stream)
            lastSpeech = .now
            state = .listening
        } catch {
            log.error("transcriber failed: \(error)")
            let message = (error as NSError).domain == "SFSpeechErrorDomain" && (error as NSError).code == 4
                ? "On-device speech isn't available here (the Simulator has no speech models)."
                : error.localizedDescription
            state = .failed(message)
            teardownAudio()
        }
    }

    /// Stops listening and returns the full transcript once the analyzer has finalized it.
    @discardableResult
    func stop() async -> String {
        guard state == .listening || state == .preparing else { return text }
        teardownAudio()
        input?.finish()
        input = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await results?.value
        results = nil
        analyzer = nil
        state = .idle
        level = 0
        return text
    }

    func reset() {
        finalized = ""
        volatile = ""
    }

    private var isFailed: Bool { if case .failed = state { true } else { false } }

    // MARK: Audio

    private func startAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothHFP, .defaultToSpeaker, .duckOthers])
        try session.setActive(true)
        let node = engine.inputNode
        let inputFormat = node.outputFormat(forBus: 0)
        if let analyzerFormat, analyzerFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: analyzerFormat)
        }
        node.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.captured(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func teardownAudio() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
        Task { @MainActor in
            self.input?.yield(analyzerInput)
            self.level = self.level * 0.6 + min(1, rms * 8) * 0.4
        }
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
        return Double(sqrt(sum / Float(buffer.frameLength)))
    }
}

extension Transcriber {
    /// Transcribes an audio file on the device (voice memos, tests).
    nonisolated static func transcribe(file url: URL, locale: Locale = Locale(identifier: "en-US")) async throws -> String {
        let model = await SpeechModel.make(locale: locale, live: false)
        try await SpeechModel.install(model.module)
        let collect = Task {
            var text = ""
            for try await result in model.results where result.isFinal { text += result.text }
            return text
        }
        let analyzer = SpeechAnalyzer(modules: [model.module])
        let file = try AVAudioFile(forReading: url)
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [model.module], considering: file.processingFormat)
            ?? file.processingFormat
        try await analyzer.prepareToAnalyze(in: format)
        // Read the file in chunks, converted to the model's format.
        let (input, feed) = AsyncStream<AnalyzerInput>.makeStream()
        let converter = AVAudioConverter(from: file.processingFormat, to: format)
        while file.framePosition < file.length {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000) else { break }
            try file.read(into: chunk)
            guard chunk.frameLength > 0 else { break }
            if let converter, file.processingFormat != format {
                let capacity = AVAudioFrameCount(Double(chunk.frameLength) * format.sampleRate / chunk.format.sampleRate + 32)
                guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { break }
                var fed = false
                var error: NSError?
                converter.convert(to: converted, error: &error) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true
                    status.pointee = .haveData
                    return chunk
                }
                if let error { throw error }
                feed.yield(AnalyzerInput(buffer: converted))
            } else {
                feed.yield(AnalyzerInput(buffer: chunk))
            }
        }
        feed.finish()
        if let end = try await analyzer.analyzeSequence(input) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collect.value.trimmingCharacters(in: .whitespaces)
    }
}

/// The on-device speech model: SpeechTranscriber where the hardware supports it, DictationTranscriber otherwise
/// (older devices, the Simulator). Both run on the iPhone.
nonisolated enum SpeechModel {
    struct Piece: Sendable {
        let text: String
        let isFinal: Bool
    }

    static func make(locale: Locale, live: Bool) async -> (module: any SpeechModule, results: AsyncThrowingStream<Piece, Error>) {
        if SpeechTranscriber.isAvailable {
            let chosen = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? Locale(identifier: "en-US")
            let module = SpeechTranscriber(
                locale: chosen, transcriptionOptions: [],
                reportingOptions: live ? [.volatileResults, .fastResults] : [], attributeOptions: [])
            return (module, stream(module.results) { Piece(text: String($0.text.characters), isFinal: $0.isFinal) })
        }
        let chosen = await DictationTranscriber.supportedLocale(equivalentTo: locale) ?? Locale(identifier: "en-US")
        let module = DictationTranscriber(locale: chosen, preset: live ? .progressiveLongDictation : .longDictation)
        return (module, stream(module.results) { Piece(text: String($0.text.characters), isFinal: $0.isFinal) })
    }

    /// Downloads the language model the first time it is needed.
    static func install(_ module: any SpeechModule) async throws {
        if await AssetInventory.status(forModules: [module]) < .installed,
            let request = try await AssetInventory.assetInstallationRequest(supporting: [module])
        {
            try await request.downloadAndInstall()
        }
    }

    private static func stream<Results: AsyncSequence & Sendable>(
        _ results: Results, _ map: @escaping @Sendable (Results.Element) -> Piece
    ) -> AsyncThrowingStream<Piece, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await result in results { continuation.yield(map(result)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct TranscriberError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
