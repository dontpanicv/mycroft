import Foundation

/// Whether the user is talking, from the microphone level against a noise floor that follows the room (slowly
/// upwards, at once downwards). Times are the audio's own clock, in seconds.
nonisolated struct VoiceActivity: Equatable {
    /// Audio time of the last loud frame.
    private(set) var lastVoice: Double = 0
    private(set) var noiseFloor = 0.002

    mutating func reset(at time: Double) {
        lastVoice = time
    }

    /// One buffer's RMS level.
    mutating func level(_ rms: Double, at time: Double) {
        noiseFloor = rms < noiseFloor ? rms : noiseFloor + (rms - noiseFloor) * 0.002
        if rms > max(noiseFloor * 4, 0.006) { lastVoice = time }
    }
}
