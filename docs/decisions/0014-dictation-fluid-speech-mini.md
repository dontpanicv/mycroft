# 0014 · Dictation with Fluid Speech Mini, loaded at launch

**Status:** accepted, implemented (21 Oct 2026). Replaces the model choice of [0011](0011-dictation-parakeet.md);
dictation still works as [0012](0012-threads-like-t3.md) describes. Amended by [0017](0017-fluid-speech-mini-only.md):
Fluid Speech Mini is the only model, and there is no Apple fallback while it loads.

**Context.** Parakeet v3 made the app about 575 MB, and switching models in Settings seemed to need a restart: a model
loaded only when dictation started, so the first dictation after a switch waited for the load. The goal was the
smallest accurate English model, ready by the time the user taps the mic, on a runtime someone else maintains.

Compared on 21 Oct 2026 (word error rates are each publisher's own runs of the Open ASR Leaderboard code):

| Model | Download | Average WER | Meetings (AMI) | iOS runtime | First load on the iPhone 17 Pro Max |
|---|---|---|---|---|---|
| **Fluid Speech Mini** (FluidVoice) | 253 MB | 4.54 (8 sets) | 8.34 | FluidAudio, as a Parakeet v3 package | **10.7 s**, then cached |
| Underdog Bark 3.0 (Conway Research) | 163 MB (≈200 MB Core ML) | 4.94 | 7.82 | none: frontend and decoder written by hand | **245 s**, again after every install |
| Parakeet TDT 0.6B v3 (NVIDIA, FluidInference) | ≈460 MB | 4.86–4.94 | 9.42 | FluidAudio | a few seconds |
| Cactus Whistle | 17 MB | not published; LibriSpeech other 10.5 | 22.9 | C library, CPU | not tried |

Bark was built and measured first: it transcribed correctly in 0.16 s, but its encoder's sparse, palettized weights
take Core ML about four minutes to prepare for the Neural Engine on the first load, and that cache is keyed to the
app's path, so every install or update pays it again. Fluid Speech Mini's dense palettes prepare in about 10 s.
Whistle is too inaccurate for dictation.

**Decision.**
- **Model.** Fluid Speech Mini (CC-BY-4.0), bundled (`ios/scripts/fetch-fluid-speech.sh`, pinned revision, every file
  checked against its hash; ≈240 MB in the app, which is ≈340 MB). FluidAudio loads it as a Parakeet v3 package
  (`Voice/FluidSpeech.swift`); its joint network is renamed `JointDecisionv3`, the name FluidAudio's v3 loader expects
  (same inputs and outputs, without the top-K ones FluidAudio reads only to filter languages). English only, as before.
- **Ready before the mic.** Fluid Speech Mini loads when the app starts and as soon as it's picked in Settings, and is
  freed when Apple's model is picked. A dictation that starts before it has loaded uses Apple's model instead of waiting:
  nothing needs a restart. `state.dictation.ready` tells the screen.
- On the iPhone 17 Pro Max, a pass over a 4-second clip takes 73 ms.

**Trade-offs:**
- The first launch after an install or update spends about 10 s preparing the model; dictation in that window is
  Apple's.
- The model is new (published 13 Oct 2026) and its numbers are self-reported. Bark scores better on meetings.
