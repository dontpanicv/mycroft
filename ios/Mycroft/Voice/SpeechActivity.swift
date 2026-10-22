import AVFoundation
import Foundation
import SoundAnalysis
import os

/// When the user speaks, from Apple's built-in sound classifier (``SpeechClassifier``), on the audio's own clock in
/// seconds.
///
/// Loudness can't tell a voice from a fan, typing or what echo cancellation leaves of Mycroft's voice, and a speech model
/// fed those finds words in them ("Thank you."). So only what the classifier calls speech is transcribed, as Pipecat
/// does: a window scored at 0.65 or more starts it, and the pause before a turn ends counts from the last such window.
nonisolated struct SpeechActivity: Equatable {
    /// Pipecat's default confidence for SoundAnalysis's `speech` class.
    static let threshold = 0.65
    /// Each score covers this much audio before its time.
    static let window = 0.5

    /// Where the first speech since the reset starts: the start of the first window scored as speech.
    private(set) var onset: Double?
    /// The end of the last window scored as speech, or the reset.
    private(set) var lastSpeech: Double = 0
    private var resetAt: Double = 0

    /// Speech was heard since the reset.
    var heard: Bool { onset != nil }

    mutating func reset(at time: Double) {
        onset = nil
        lastSpeech = time
        resetAt = time
    }

    /// The classifier's confidence that the window ending at `time` is speech.
    mutating func score(_ confidence: Double, at time: Double) {
        // A window reaching back before the reset holds what was cleared: Mycroft's own voice, or a turn already sent.
        guard time - Self.window >= resetAt, confidence >= Self.threshold else { return }
        if onset == nil { onset = time - Self.window }
        lastSpeech = max(lastSpeech, time)
    }
}

/// SoundAnalysis's built-in classifier, scoring the microphone for speech every tenth of a second over half-second
/// windows. It is part of iOS: nothing to download or load.
nonisolated final class SpeechClassifier: NSObject, SNResultsObserving, @unchecked Sendable {
    private let analyzer: SNAudioStreamAnalyzer
    private let format: AVAudioFormat
    /// Its own queue: the analyzer can block while the model catches up.
    private let queue = DispatchQueue(label: "dev.mycroft.speech-classifier")
    /// Frames analyzed, only on `queue`.
    private var position: AVAudioFramePosition = 0
    private let scored: @Sendable (_ confidence: Double, _ time: Double) -> Void

    /// `scored` gets each window's speech confidence and the audio time it ends at (frames analyzed over the rate).
    init(format: AVAudioFormat, scored: @escaping @Sendable (_ confidence: Double, _ time: Double) -> Void) throws {
        analyzer = SNAudioStreamAnalyzer(format: format)
        self.format = format
        self.scored = scored
        super.init()
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: SpeechActivity.window, preferredTimescale: CMTimeScale(format.sampleRate))
        request.overlapFactor = 0.8
        try analyzer.add(request, withObserver: self)
    }

    /// The next samples, in `format`.
    func analyze(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        queue.async { [self] in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                let channel = buffer.floatChannelData?[0]
            else { return }
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            analyzer.analyze(buffer, atAudioFramePosition: position)
            position += AVAudioFramePosition(samples.count)
        }
    }

    func stop() {
        queue.async { [self] in analyzer.removeAllRequests() }
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        scored(result.classification(forIdentifier: "speech")?.confidence ?? 0, result.timeRange.end.seconds)
    }

    func request(_ request: SNRequest, didFailWithError error: any Error) {
        Logger(subsystem: "dev.mycroft", category: "listener").error("speech classifier failed: \(error)")
    }
}
