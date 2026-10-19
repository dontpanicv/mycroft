import AVFoundation
import Foundation
import Speech
import os

/// Speech to text of a recording, on the iPhone itself (voice memos, tests). Live listening is ``Listener``.
nonisolated enum Transcriber {}

extension Transcriber {
    /// Transcribes an audio file on the device (voice memos, tests).
    nonisolated static func transcribe(file url: URL, locale: Locale = Locale(identifier: "en-US")) async throws -> String {
        let model = await SpeechModel.make(locale: locale)
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

    static func make(locale: Locale) async -> (module: any SpeechModule, results: AsyncThrowingStream<Piece, Error>) {
        if SpeechTranscriber.isAvailable {
            let chosen = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? Locale(identifier: "en-US")
            let module = SpeechTranscriber(
                locale: chosen, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
            return (module, stream(module.results) { Piece(text: String($0.text.characters), isFinal: $0.isFinal) })
        }
        let chosen = await DictationTranscriber.supportedLocale(equivalentTo: locale) ?? Locale(identifier: "en-US")
        let module = DictationTranscriber(locale: chosen, preset: .longDictation)
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

/// Audio taps run on a real-time audio queue. A closure written inside main-actor code would inherit main-actor
/// isolation and trap there ("dispatch_assert_queue"), so tap blocks are made here, outside any actor.
nonisolated enum AudioTap {
    static func block(_ handle: @escaping @Sendable (AVAudioPCMBuffer) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in handle(buffer) }
    }

    static func completion(_ handle: @escaping @Sendable () -> Void) -> AVAudioNodeCompletionHandler {
        { handle() }
    }
}

struct TranscriberError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
