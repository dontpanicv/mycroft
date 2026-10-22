# 0017 · Fluid Speech Mini is the only dictation model

**Status:** accepted, implemented (21 Oct 2026). Amends [0014](0014-dictation-fluid-speech-mini.md): no Apple model, no
choice in Settings.

**Context.**
- Fluid Speech Mini has been good on the iPhone, and nobody picks Apple's model.
- The fallback cost more than it gave. Dictation used Apple's SpeechTranscriber until Fluid Speech Mini had loaded (about
  10 s after each install or update), so a conversation started soon after a launch heard with Apple's model.
- Apple's recognizer keeps its own copy of the audio and finalizes a result 1–2 s after the speech, so dropping
  Mycroft's own voice from what the microphone heard ([0016](0016-conversation-mode.md)) didn't reach it. Its echo came
  back as the user's turn, and covering it took a second set of safeguards.

**Decision.**
- Fluid Speech Mini, bundled, is the only dictation model. Settings has no dictation section, and the `dictation.engine`
  op is gone; `state.dictation` is `{ bundled, ready }`.
- Before the model has loaded, the microphone still starts at once: the audio is kept and transcribed when the model is
  ready, so the first words arrive a little later rather than from another model.
- Apple's Speech framework is gone from the app, with its usage description: `Listener` keeps 16 kHz samples and
  nothing else, and dropping audio is all it takes to drop words.
- A build without the model has no dictation and says so (`ios/scripts/fetch-fluid-speech.sh`).

**Trade-offs:**
- Words appear in steps of about a second, never word by word.
- Right after an install or update, the first dictation waits for the model's first load (about 10 s).
