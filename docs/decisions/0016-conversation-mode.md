# 0016 · Conversation mode with Phonon, and Apple's model as an experiment

**Status:** accepted, implemented (21 Oct 2026), not yet measured on an iPhone. Builds on [0014](0014-dictation-fluid-speech-mini.md)
for hearing; brings back speaking, which [0011](0011-dictation-parakeet.md) removed.

**Context.**
- Dictation is good, but talking with Mycroft means dictating, sending and reading. A conversation should be
  hands-free: talk, hear the answer, talk again, with as little silence as possible.
- Apple's voices sound like a machine. The voice has to run on the iPhone; no cloud service.
- A turn can take a minute of tool calls. Waiting for the whole run before saying anything leaves the user in silence.
- Pi Durable already streams: the partial answer is committed every `partialInterval` (100 ms by default) and every
  view of the conversation carries it (`live.generation.message`). Codex models write a short message before calling
  tools, and their reasoning summaries arrive as thinking blocks. Nothing in pi-durable needs to change.

**Decision.**
- **A conversation is a mode of a thread.** A wave button next to the mic starts it; a dock takes the composer's place,
  with what is being said, an orb, mute and end. Ending it stops the microphone and the voice, never the run. In a new
  thread, the first words create the thread.
- **It runs natively** (`Voice/VoiceChat.swift`), like dictation, so it carries on with the screen locked.
- **Hearing.** The listener stays on in a conversation and hands over each turn (`take()`) while it keeps listening.
  A pause after the user's words ends their turn: 0.8 s after a finished sentence, 1.2 s otherwise, 2 s after "and…",
  "um" or a comma (`TurnEnd`, after 0010's detector). The words go to the thread as a message, or as a steer while a
  run works.
- **Only speech is a turn** (22 Oct 2026, after Pipecat's Little Voices). The first build ended a turn on loudness and
  sent whatever the recognizer returned; while the agent worked, Fluid Speech Mini transcribed the room every second and
  turned it into "Thank you." and "I know", which went to the thread as the user. Now Apple's built-in sound classifier
  (SoundAnalysis, `speech` class, half-second windows every 0.1 s, confidence 0.65 as Pipecat uses) decides what is
  speech (`SpeechActivity`). Nothing is transcribed until it hears speech; the words start at that window and end
  0.3 s after the last one; the pause counts from it. The same holds for dictation.
- **Speaking.** It follows the thread's views and says each new sentence of the run's text as it streams: the text
  of a run only grows (the streaming message is committed in its place), so what has been said is a count of
  characters (`Narration`). Markdown is read as words; code blocks, tables and links aren't read. Partials are now
  committed every 40 ms.
- **The agent knows it is being heard.** While a conversation is on, the thread's instructions ask it to say what it
  is about to do before using tools, write as it would speak, keep it short, and never repeat in its answer what it
  already said in the turn. The model sees its own earlier messages, so that holds. Ending the conversation removes
  the instructions.
- **The voice** is Gradium's Phonon 31m (Apache-2.0, published 20 Oct 2026), in FluidInference's Core ML conversion,
  run by FluidAudio's `PocketTtsSmallManager` (on its `main` branch until a release has it). It is bundled
  (`ios/scripts/fetch-phonon.sh`, ≈150 MB with the English voices), loads when a conversation starts, and makes one
  sentence while the previous one plays, each streamed in 80 ms frames. Settings picks one of six English voices and
  plays a sample. Vendor numbers: about 20 ms to first audio and 19–25× real time on an M5 Pro.
- **Cutting in, and never hearing itself.** The voice plays through the listener's engine.
  - With headphones there is no echo, and no echo cancellation: it can't play to AirPods' music profile, so iOS
    moves the voice to the iPhone's speaker (while still naming the AirPods), where the microphone hears it. Talking
    over Mycroft stops it at once.
  - When headphones come or go during a conversation, the audio restarts set up for the new route (echo cancellation
    on or off), and Mycroft says again the sentence it was in and what came after it.
  - Whether headphones are connected is told by the devices (the route's headphone outputs, or a headset or AirPods
    among the inputs), not by where the sound goes: that depends on the setup itself, and judging by it switched a
    conversation with AirPods between the two setups every second, so it heard almost nothing (22 Oct 2026). More
    than three restarts in ten seconds stop the following.
  - With headphones the audio stays in the default mode: dictation's measurement mode, with the iPhone's own
    microphone, moves the sound from the AirPods to the iPhone's speaker.
  - On the speaker, echo cancellation is on (the system's echo-cancelled input where the route has it, otherwise
    voice processing), but enough of the voice comes back for the recognizer to turn it into garbled words that
    can't be told from the user's. Only "stop", "wait" and the like cut in there.
  - Everything heard while Mycroft speaks, and for 0.7 s after, is dropped as audio, before a late transcription
    can turn it into a message. A tap on the orb always cuts in. After a cut-in nothing more of that run is said
    until the user's next message.
  - Every turn goes as a steer: talking while Mycroft works redirects it.
- **Apple's on-device model, as an experiment.** Settings → Model picks what new threads use: Sol 6.1 or Apple's
  on-device Foundation Model (`FoundationModelsProvider` in PiDurableKit). A thread keeps the model it started with.
  The on-device window is a few thousand tokens, so Apple's threads get only Mycroft's own extension (no machines,
  desktop, self-editing or code mode) and say so in their instructions. Compaction is sized for that window
  (`Settings.Compaction.forContextWindow`); thresholds count from each model's window, so Sol's threads still compact
  only when nearly full, keeping less verbatim.

**Trade-offs:**
- Nothing is measured on an iPhone yet: first audio, real-time factor with dictation sharing the Neural Engine, memory
  with both models loaded, and how well echo cancellation keeps Mycroft from cutting itself off.
- The app grows by ≈150 MB.
- Echo cancellation is a call's processing: it may make dictation in a conversation a little less accurate than in the
  composer.
- FluidAudio is pinned to an unreleased commit.
- English only, like dictation.
