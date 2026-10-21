# 0011 · Dictation with Parakeet v3, bundled; read aloud removed

**Status:** accepted, implemented (19 Oct 2026). Amends [0010](0010-voice-in-every-thread.md). Amended by
[0012](0012-threads-like-t3.md): no turn ends on a pause; the user starts and stops dictation. The model is replaced by
Fluid Speech Mini in [0014](0014-dictation-fluid-speech-mini.md).

**Context.**
- Dictation on the iPhone was noticeably worse than FluidVoice on a Mac, which runs NVIDIA's Parakeet TDT 0.6B v3.
- The listener was also set up against accuracy:
  - `.fastResults` on SpeechTranscriber trades accuracy for speed;
  - voice processing (echo cancellation, for reading aloud) ran on the microphone all the time, and it is made for
    calls;
  - `.allowBluetoothHFP` took AirPods' narrow-band call microphone.
- Read aloud isn't wanted. Good dictation is the goal.

**Measured** on a Mac with the same audio for every model: 40 conversational clips from non-native English speakers
(EdAcc: Bulgarian, Lithuanian, Sinhalese; 744 words) and 40 clean read clips (LibriSpeech; 678 words). Word error
rate:

| | Accented, conversational | Clean, read |
|---|---|---|
| Apple SpeechTranscriber, as used (`.fastResults`) | 16.4% | 3.4% |
| Apple SpeechTranscriber, without `.fastResults` | 15.2% | 2.7% |
| Apple DictationTranscriber | 30.9% | 10.9% |
| Parakeet v3, whole turn at once | **11.3%** | 3.5% |
| Parakeet v3, streaming | 12.1% | 4.0% |

Small sets, but the gap on accented speech is consistent: "yes it was robin hood" came out as "Yes, it was running
out." from Apple and right from Parakeet. It transcribed a 6 s clip in about 60 ms.

**Decision.**
- **Parakeet v3 is bundled in the app** (`ios/scripts/fetch-parakeet.sh` downloads it into `ios/Models`, outside git,
  and the build copies it into the app; ~460 MB). It runs through FluidAudio (Apache-2.0) on the Neural Engine,
  loads when a thread opens, and stays loaded.
- **Settings → Dictation** switches between Parakeet (the default) and Apple. The choice applies from the next turn.
- **With Parakeet**, the listener keeps the turn's audio (16 kHz) and transcribes the whole turn again every second
  while the user talks and as soon as they pause, so the text is current before a pause ends the turn. The sent text
  is one pass over the whole turn, the most accurate way to run it. Words arrive in short steps rather than one by
  one. If the model is still loading, the audio is kept and transcribed once it is ready.
- **With Apple**, the words appear as they are spoken, now without `.fastResults`.
- **The microphone** has no voice processing. AirPods that can record at full bandwidth (iOS 26's
  `.bluetoothHighQualityRecording`) are used; otherwise the iPhone's own microphone in `.measurement` mode, never the
  narrow-band call microphone.
- **Read aloud is gone**, and with it the speech synthesis, the echo cancellation and the listening between turns:
  one turn is one message, and the listener stops after sending.

**Trade-offs:**
- The app is about 460 MB larger.
- With Parakeet the text trails speech by up to a second. End of turn still runs on the microphone level, so it is
  as quick as before.
- Each pass transcribes the whole turn again, so long dictation costs more as it grows; passes are spaced out to at
  least three times the last one's duration.
- Parakeet's custom vocabulary (which would fix machine names) needs a second model, so it isn't used yet.
