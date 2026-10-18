# Research

How we got from "what is Mario doing on his phone?" to Mycroft. Collected 17–18 October 2026.

## 1. Mario's pim (Android, Pi Durable)

[`pages/01-mario-pi-mobile-architecture.html`](pages/01-mario-pi-mobile-architecture.html) is reconstructed from about 350 of [@badlogicgames](https://x.com/badlogicgames)'s posts and the public [earendil-works/pi](https://github.com/earendil-works/pi) repo.

- **Everything except the LLM runs on his Pixel:** a Chord server host, one session worker per conversation, Pi Durable on SQLite, and a React UI with HMR.
- **The recursion:** the agent's working directory is the app's own source. On an edit, the web UI hot-reloads and the workers are killed and respawned. Pi Durable resumes the turn that made the edit.
- **The "Hetzner trick":** the execution environment is resolved per tool call. A thread can move its hands to a remote machine through `pi-env` (a Rust daemon over SSH) while its brain stays on the phone.
- **History:** Termux and a browser (Oct 3), then a native APK "Pi Mobile" (Oct 4–11), then "p2" on chord2 (Oct 12 onward).

## 2. Can it work on iOS?

[`pages/02-pi-ios-verified.html`](pages/02-pi-ios-verified.html) audits every claim against sources. [`pages/03-pi-ios-on-device.html`](pages/03-pi-ios-on-device.html) and [`pages/phone-architecture.html`](pages/phone-architecture.html) show the on-device design: runtimes, isolation boundaries, and the self-edit loop.

- No local shell, so the hands are always remote.
- Pi Durable runs on JavaScriptCore ([PiDurableKit](https://github.com/finnvoor/PiDurableKit)).
- App Store guideline 2.5.2 rules out self-modifying apps, so Mycroft is a personal install.

## 3. Background execution spike (iOS 27, real iPhone)

[`background-spike.md`](background-spike.md), [`pages/device-report.html`](pages/device-report.html), raw summaries in [`spike-results/`](spike-results/), and the source in [`../../spikes/background`](../../spikes/background).

| Test (iPhone 17 Pro Max, iOS 27.2) | Result |
|---|---|
| `BGContinuedProcessingTask` with progress reports | 600 steps in **616 s**, 589 of them in the background |
| `LongRunningIntent` with progress reports | 600 steps in **622 s**, in the background |
| `LongRunningIntent` without progress reports | Cancelled after 58 s |
| Self-edit + `JSContext` swap | Generation 1 → 2 mid-run, state restored, new behavior executed |
| Process kill + relaunch | Generation 2 restored from checkpoint |
| Phone locked | 53 s of work observed with protected data unavailable |

Tesla's always-on phone key works differently: iOS wakes the app for Bluetooth events. It doesn't keep code running continuously.

## 4. Desktop control

[`pages/phone-desktop-control.html`](pages/phone-desktop-control.html)

- **Reference implementations:** [pi-computer-use](https://github.com/injaneity/pi-computer-use) (observe/act/verify backend), [jev-use](https://github.com/savka777/jev-use) (Accessibility → Jev → act → verify, deciding the operation and its targets in one request), and [Computah](https://github.com/musubipapi/computah) (voice control of macOS).
- **What's missing:** stock pi-env has no desktop operations, so a Mac needs a helper running in the logged-in GUI session.

## 5. Voice

[`pages/voice-interface.html`](pages/voice-interface.html)

- **Recommended approach:** GPT-Live with [client delegation](https://developers.openai.com/api/docs/guides/live-delegation?delegation-mode=client).
- **How it fits Pi Durable:** Pi Durable's submissions (with dedupe ids), steering and cancellation map onto the live model's function calls.

## 6. Hand-off to Pi on a server ([pi-phone](https://github.com/picassio/pi-phone))

- **How it works:** "Continue in Pi" exports the conversation as a native Pi `.jsonl` session on the remote machine and records the last message both sides share. "Bring back" imports only the entries added after that message, and translates Pi's compactions.
- **Conflicts:** if both sides advanced, it refuses to merge and offers a copy instead.
- **Caveat:** this moves context, not a running process.

Reference: commit [`1071949`](https://github.com/picassio/pi-phone/blob/10719493fdc35c6460e2a3f95d6192b3a8c6fc17/src/server/pi-handoff.ts).
