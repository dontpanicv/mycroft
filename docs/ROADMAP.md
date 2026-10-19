# Roadmap

Each milestone ends with something running on the iPhone and a short evidence note in `docs/research/`.

| # | Milestone | Done when | Status |
|---|---|---|---|
| M0 | **Repo and research** | Research, architecture, design direction and decisions are public. | ✅ 18 Oct |
| M1 | **Host and runtime** | The SwiftUI shell with the threads UI runs a Pi Durable Harness in a `JSContext` against the native SQLite bridge. Storage conformance passes in the simulator, using the faux provider. | ✅ 18 Oct: built on [PiDurableKit](https://github.com/finnvoor/PiDurableKit), not a custom bridge |
| M2 | **Real models** | Device-code ChatGPT login (plus dev `auth.json` import). Sol 6.1 streams through the `URLSession` fetch bridge. Multiple threads work end to end. | ✅ 18 Oct: live UI test answers in ~45 s round trip |
| M3 | **Background runs** | A run continues in the background via `BGContinuedProcessingTask`, with Live Activity progress and an "Ask Mycroft" `LongRunningIntent`. A killed run resumes on relaunch. Measured on the iPhone. | 🟡 continued processing + Live Activity / Dynamic Island in place; the Simulator has no continued processing, so needs an iPhone run |
| M4 | **Self-modification** | Generations, a self-test, atomic activation and crash-loop rollback work. The agent edits itself mid-run and the run continues. | ✅ 18 Oct: the agent added a `coin` tool, activated it and called it in one turn |
| M5 | **Hands v1** | A Rust daemon (pi-env-compatible protocol plus jobs) with SSH from iOS, pairing, an install script for macOS and Linux, and jobs that survive the phone disconnecting. | ✅ 18 Oct: one-line install served by the iPhone paired this Mac; a Linux box paired too; one prompt ran a server on Linux and a client on the Mac |
| M6 | **Computer use** | The macOS LaunchAgent can observe and act on the AX tree. The Jev decision loop with verification runs from the phone. First task: create a note in Notes. | ✅ 18 Oct: from the phone, `desktop_do` opened Notes on the Mac, pressed New Note and typed the text (3 Jev steps, 8 s); `ui_screenshot` confirmed it |
| M7 | **Voice** | Talk in every thread: hold or tap-and-pause to send, answers read aloud, talking interrupts, works with the screen locked ([ADR 0010](decisions/0010-voice-in-every-thread.md)). GPT-Live was dropped for cost. | 🟡 built 19 Oct; end-of-turn rules checked against the real recognizer on a Mac; first test on the iPhone pending (the Simulator has no speech models) |
| M4b | **Self-editable screen** | The whole screen is web code in each generation; the agent changes it and it reloads in place with the conversation intact. Broken screens never go live. | ✅ 19 Oct: asked to add a line to its home screen, Mycroft read its UI code, wrote it, previewed it off-screen, activated generation 3, and the screen hot-swapped mid-thread ([ADR 0009](decisions/0009-self-editable-web-ui.md)) |
| M8 | **Hand-off and polish** | "Continue in Pi" on a hands host (the pi-phone pattern), a self/generations screen, docs. | ⬜ |
