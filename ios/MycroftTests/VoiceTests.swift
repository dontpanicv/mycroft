import Foundation
import Testing

@testable import Mycroft

/// When the user speaks, from the classifier's scores on the audio's clock: only speech is transcribed.
@Suite("Speech activity")
struct SpeechActivityTests {
    @Test func noiseIsNotSpeech() {
        var speech = SpeechActivity()
        speech.reset(at: 0)
        // A fan, typing, or what echo cancellation leaves: loud, but scored low.
        for step in 5..<100 { speech.score(0.3, at: Double(step) * 0.1) }
        #expect(!speech.heard)
        #expect(speech.lastSpeech == 0)
    }

    @Test func speechStartsWithItsWindowAndThePauseCountsFromItsEnd() {
        var speech = SpeechActivity()
        speech.reset(at: 0)
        speech.score(0.2, at: 1.0)
        speech.score(0.9, at: 1.125)
        #expect(speech.onset == 0.625)
        speech.score(0.8, at: 1.25)
        speech.score(0.1, at: 1.375)
        #expect(speech.onset == 0.625)
        #expect(speech.lastSpeech == 1.25)
    }

    @Test func windowsFromBeforeAResetAreIgnored() {
        var speech = SpeechActivity()
        speech.reset(at: 10)
        // These windows still hold what was cleared: Mycroft's voice, or the turn just sent.
        speech.score(0.95, at: 10.1)
        speech.score(0.95, at: 10.4)
        #expect(!speech.heard)
        speech.score(0.95, at: 10.6)
        #expect(speech.onset == 10.1)
    }
}

/// What conversation mode says: a streaming run's text, a sentence at a time, each once.
@Suite("Narration")
struct NarrationTests {
    @Test func sentencesWaitUntilTheyEnd() {
        var narration = Narration()
        #expect(narration.update(anchor: "1", pieces: ["Okay, let me look"], streaming: true) == [])
        #expect(narration.update(anchor: "1", pieces: ["Okay, let me look into it. I'll check"], streaming: true)
            == ["Okay, let me look into it."])
        #expect(narration.update(anchor: "1", pieces: ["Okay, let me look into it. I'll check the logs."], streaming: true) == [])
        // The streaming message is committed in the same place, and a tool round follows.
        #expect(narration.update(anchor: "1", pieces: ["Okay, let me look into it. I'll check the logs."], streaming: false)
            == ["I'll check the logs."])
        #expect(narration.update(anchor: "1", pieces: ["Okay, let me look into it. I'll check the logs.", "They're clean"], streaming: true) == [])
        #expect(narration.update(anchor: "1", pieces: ["Okay, let me look into it. I'll check the logs.", "They're clean."], streaming: false)
            == ["They're clean."])
    }

    @Test func aNewUserMessageStartsAgain() {
        var narration = Narration()
        narration.skip(anchor: "1", pieces: ["An old answer."])
        #expect(narration.update(anchor: "1", pieces: ["An old answer."], streaming: false) == [])
        #expect(narration.update(anchor: "5", pieces: ["Sure."], streaming: false) == ["Sure."])
    }

    @Test func cuttingInDropsTheRest() {
        var narration = Narration()
        #expect(narration.update(anchor: "1", pieces: ["One. Two"], streaming: true) == ["One."])
        narration.skip()
        #expect(narration.update(anchor: "1", pieces: ["One. Two. Three."], streaming: false) == [])
    }

    @Test func markdownIsReadAsWords() {
        var narration = Narration()
        let text = """
            ## Results
            - **Disk** is at `82%`, see [the report](https://example.com/r).
            1. Restart it.
            ```
            sudo reboot
            ```
            | a | b |
            Done 🎉
            """
        #expect(narration.update(anchor: "1", pieces: [text], streaming: false)
            == ["Results", "Disk is at 82%, see the report.", "Restart it.", "Done"])
    }

    @Test func abbreviationsAndNumbersDontEndSentences() {
        let (sentences, _) = Narration.sentences(in: "Use e.g. the 3.5 build. J. R. R. Tolkien wrote it. ", final: false)
        #expect(sentences == ["Use e.g. the 3.5 build.", "J. R. R. Tolkien wrote it."])
    }
}

@Suite("Turn end")
struct TurnEndTests {
    @Test func pausesDependOnHowTheWordsEnd() {
        #expect(TurnEnd.pause(after: "What's on bender?") == 0.8)
        #expect(TurnEnd.pause(after: "check the build and") == 2.0)
        #expect(TurnEnd.pause(after: "So, um,") == 2.0)
        #expect(TurnEnd.pause(after: "open the logs") == 1.2)
        #expect(TurnEnd.pause(after: "") == .infinity)
    }

    @Test func mycroftsOwnVoiceIsntTheUser() {
        let said = "I'll check the logs on bender two."
        #expect(Echo.isEcho("check the logs", of: said))
        #expect(Echo.isEcho("logs", of: said))
        #expect(!Echo.isEcho("No, look at the database instead", of: said))
        #expect(!Echo.isEcho("Stop", of: said))
    }

    /// On the speaker, Mycroft's voice comes back garbled (these came back on an iPhone 17 Pro Max, 21 Oct 2026), so
    /// only an interruption cuts it off there.
    @Test func onTheSpeakerOnlyStopCutsIn() {
        let said = "I’ll check GLaDOS’s CPU load, memory pressure, and the processes using the most resources too."
        #expect(!Echo.interrupts("Well-the-clados is TPL, highway pressure, and the process that we use for resources too.", of: said))
        #expect(!Echo.interrupts("I'll add Ramu.", of: "I’ll add RAM usage to Mycroft’s homepage alongside the machine status."))
        #expect(Echo.interrupts("Stop.", of: said))
        #expect(Echo.interrupts("wait, wait", of: said))
        #expect(!Echo.interrupts("wait", of: "Wait a moment while I check."))
    }
}

/// The listener before it starts: what the page and a conversation see of it.
@Suite("Listener")
struct ListenerTests {
    @Test func anIdleListenerIsOffAndDictating() async {
        let listener = Listener()
        let snapshot = listener.snapshot()
        #expect(snapshot["state"] as? String == "off")
        #expect(snapshot["text"] as? String == "")
        #expect(snapshot["elapsed"] as? Int == 0)
        // Echo cancellation is only ever on in a conversation.
        #expect(!listener.echoCancelled)
        // Nothing to stop, cancel or hand back.
        #expect(await listener.stop() == "")
        #expect(await listener.take() == "")
        listener.cancel()
        listener.clear()
        listener.shutDown()
        #expect(listener.state == .off)
        #expect(listener.owner == nil)
    }
}
