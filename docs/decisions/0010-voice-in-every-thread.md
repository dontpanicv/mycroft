# 0010 · Voice in every thread, on the iPhone

**Status:** accepted, implemented (19 Oct 2026). Supersedes [0007](0007-voice-gpt-live-client-delegation.md).

**Context.**
- Voice had its own screen. With an OpenAI key it ran GPT-Live, at $0.05 a minute of open session, billed separately
  from ChatGPT. Without one, it ran a slow on-device loop.
- Dictation in a thread meant tapping the mic, watching the text, then pressing send.
- The on-device loop ended a turn 1.4 s after the transcript last *changed*. The recognizer rewrites ("finalizes")
  its text about 1.5–2 s of audio after the speech ends, and that rewrite restarted the clock, so the user had to
  stay quiet for about 3 s.
- What's wanted is fluid speaking in the normal threads, not a phone call. English only.

**Decision.** One on-device listener (`ios/Mycroft/Voice/Listener.swift`) serves whichever thread is open. The
composer drives it, and its loop runs natively, so it carries on with the screen locked.

- **Recognition:** Apple's SpeechTranscriber in English, kept loaded between turns (`modelRetention:
  .processLifetime`). Measured against the alternatives, it is as accurate as on-device English gets (about 2% word
  errors on clean speech), and free.
- **End of turn** (`TurnDetector`, measured on the audio's own clock):
  - The pause is counted from the last loud frame, against a noise floor that follows the room, so it starts the
    moment the user stops.
  - The pause needed depends on how the words end: 0.7 s after a finished sentence, 1.2 s otherwise, 2 s after
    "and…", "um" or a comma.
  - In a loud room, 2.5 s without a new word ends the turn anyway. Finalizing adds no words, so it never restarts
    the clock.
  - Tested against the real recognizer streaming a recording with pauses: the turn ended about 0.7 s after the
    speech, and not during a 1.3 s pause after "and then, um,".
- **In the composer:**
  - Hold the mic to talk, release to send. Slide up to lock, left to cancel.
  - A quick tap listens until a pause. A ring then fills around the send button for 1 s and the turn sends itself.
    Talking again cancels it, and tapping the mic keeps the words in the draft to edit.
  - "Send it" sends at once; "scratch that" clears the turn.
  - Typed text before speaking goes first.
- **Read aloud** (a toggle in the thread header):
  - Answers are read with the best installed English voice, and listening goes on between turns.
  - The reading plays through the same audio engine as the microphone, with voice processing (echo cancellation),
    so talking over it stops it. Talking while Mycroft works steers the run.
  - Short tones mark listening, sent and answer ready.
- **Names:** the recognizer has no custom vocabulary that works (contextual strings had no effect on SpeechTranscriber
  in a test: "Bender" stays "Vendor"). Instead, the machines prompt tells the agent that spoken names arrive as
  sound-alikes, so "vendor too" can be matched to bender-2.

**Trade-offs:**
- No natural conversational voice: Apple's TTS reads the answers. GPT-Live and the OpenAI key are gone.
- English only. Apple's newer model has no Czech; Parakeet v3 on device would be the route if that changes.
- The thresholds are tuned on recordings and a simulation; real rooms and AirPods may need adjusting on the phone.
