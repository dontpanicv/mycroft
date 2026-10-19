import Foundation
import Testing

@testable import Mycroft

/// When the user is talking, on the audio's clock: Parakeet transcribes again as soon as they pause.
@Suite("Voice activity")
struct VoiceActivityTests {
    @Test func speechMarksVoiceAndSilenceDoesnt() {
        var activity = VoiceActivity()
        activity.reset(at: 0)
        for step in 0..<20 { activity.level(0.001, at: Double(step) * 0.1) }
        #expect(activity.lastVoice == 0)
        activity.level(0.05, at: 2.0)
        #expect(activity.lastVoice == 2.0)
        activity.level(0.001, at: 2.1)
        #expect(activity.lastVoice == 2.0)
    }

    @Test func aLoudRoomRaisesTheFloor() {
        var activity = VoiceActivity()
        activity.reset(at: 0)
        // A steady hum counts as voice at first, then becomes the floor.
        for step in 0..<3000 { activity.level(0.02, at: Double(step) * 0.05) }
        #expect(activity.noiseFloor > 0.015)
        let before = activity.lastVoice
        activity.level(0.02, at: 200)
        #expect(activity.lastVoice == before)
        activity.level(0.2, at: 201)
        #expect(activity.lastVoice == 201)
    }
}
