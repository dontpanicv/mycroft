import Foundation
import Testing

@testable import Mycroft

/// When a spoken turn ends, on the audio's clock, and the commands said at its end.
@Suite("Voice turns")
struct VoiceTurnTests {
    /// Speech from 0 to `until` seconds (loud buffers every 0.1 s), then quiet; the words arrive as they're spoken.
    func speak(_ words: [(String, Double)], until: Double) -> TurnDetector {
        var detector = TurnDetector()
        detector.reset(at: 0)
        var time = 0.0
        var text = ""
        var next = words[...]
        while time <= until {
            detector.level(0.05, at: time)
            while let word = next.first, word.1 <= time {
                text += (text.isEmpty ? "" : " ") + word.0
                detector.heard(text, at: time)
                next = next.dropFirst()
            }
            time += 0.1
        }
        return detector
    }

    func quiet(_ detector: inout TurnDetector, from start: Double, to end: Double) {
        var time = start
        while time <= end {
            detector.level(0.0005, at: time)
            time += 0.1
        }
    }

    @Test func aFinishedSentenceEndsAfterAShortPause() {
        var detector = speak([("Check", 0.2), ("the", 0.4), ("build.", 0.8)], until: 1.0)
        quiet(&detector, from: 1.1, to: 1.6)
        #expect(!detector.ended("Check the build.", at: 1.6))
        quiet(&detector, from: 1.7, to: 1.8)
        #expect(detector.ended("Check the build.", at: 1.8))
    }

    @Test func aTrailingWordWaitsLonger() {
        var detector = speak([("And", 0.2), ("then", 0.5), ("um", 0.9)], until: 1.0)
        quiet(&detector, from: 1.1, to: 2.5)
        #expect(!detector.ended("And then um", at: 2.5))
        quiet(&detector, from: 2.6, to: 3.1)
        #expect(detector.ended("And then um", at: 3.1))
    }

    @Test func finalizingTheTextDoesntRestartTheClock() {
        var detector = speak([("Run", 0.2), ("the", 0.4), ("tests", 0.8)], until: 1.0)
        quiet(&detector, from: 1.1, to: 2.0)
        // 1.5 s later the recognizer rewrites the same words with punctuation: no new word.
        detector.heard("Run the tests.", at: 2.0)
        #expect(detector.ended("Run the tests.", at: 2.1))
    }

    @Test func aLoudRoomEndsOnTheWordsAlone() {
        var detector = speak([("Open", 0.2), ("the", 0.4), ("logs.", 0.8)], until: 3.4)
        #expect(!detector.ended("Open the logs.", at: 3.2))
        #expect(detector.ended("Open the logs.", at: 3.4))
    }

    @Test func nothingSaidNeverEnds() {
        var detector = TurnDetector()
        detector.reset(at: 0)
        quiet(&detector, from: 0, to: 10)
        #expect(!detector.ended("", at: 10))
    }

    @Test func pausesFollowHowTheWordsEnd() {
        #expect(TurnDetector.pause(after: "What time is it?") == TurnDetector.finished)
        #expect(TurnDetector.pause(after: "Restart nginx on bender") == TurnDetector.unsure)
        #expect(TurnDetector.pause(after: "Restart nginx and") == TurnDetector.trailing)
        #expect(TurnDetector.pause(after: "Look at the logs,") == TurnDetector.trailing)
        #expect(TurnDetector.pause(after: "Uh") == TurnDetector.trailing)
    }

    @Test func commandsAtTheEnd() {
        #expect(VoiceCommand.parse("Restart nginx, send it.") == ("Restart nginx", .send))
        #expect(VoiceCommand.parse("Send it") == ("", .send))
        #expect(VoiceCommand.parse("Delete the branch. Scratch that!") == ("Delete the branch", .clear))
        #expect(VoiceCommand.parse("Never mind") == ("", .clear))
        // Not at the end, or part of another word: plain text.
        #expect(VoiceCommand.parse("Send it to the server later") == ("Send it to the server later", nil))
        #expect(VoiceCommand.parse("Please resend it") == ("Please resend it", nil))
        #expect(VoiceCommand.parse("  Hello there ") == ("Hello there", nil))
    }

    @Test func aCommandNeedsOnlyAShortPause() {
        var detector = speak([("Restart", 0.2), ("nginx", 0.5), ("send", 0.8), ("it", 1.0)], until: 1.1)
        quiet(&detector, from: 1.2, to: 1.7)
        #expect(detector.ended("Restart nginx send it", at: 1.7))
    }
}
