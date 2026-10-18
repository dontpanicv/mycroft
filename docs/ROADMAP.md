# Roadmap

Each milestone ends with something running on the iPhone and a short evidence note in `docs/research/`.

| # | Milestone | Done when | Status |
|---|---|---|---|
| M0 | **Repo and research** | Research, architecture, design direction and decisions are public. | ✅ 18 Oct |
| M1 | **Host and runtime** | The SwiftUI shell with the threads UI runs a Pi Durable Harness in a `JSContext` against the native SQLite bridge. Storage conformance passes in the simulator, using the faux provider. | ✅ 18 Oct: built on [PiDurableKit](https://github.com/finnvoor/PiDurableKit), not a custom bridge |
| M2 | **Real models** | Device-code ChatGPT login (plus dev `auth.json` import). Sol 6.1 streams through the `URLSession` fetch bridge. Multiple threads work end to end. | ✅ 18 Oct: live UI test answers in ~45 s round trip |
| M3 | **Background runs** | A run continues in the background via `BGContinuedProcessingTask`, with Live Activity progress and an "Ask Mycroft" `LongRunningIntent`. A killed run resumes on relaunch. Measured on the iPhone. | 🟡 code in place; needs an iPhone run |
| M4 | **Self-modification** | Generations, a self-test, atomic activation and crash-loop rollback work. The agent edits itself mid-run and the run continues. | ✅ 18 Oct: the agent added a `coin` tool, activated it and called it in one turn |
| M5 | **Hands v1** | A Rust daemon (pi-env-compatible protocol plus jobs) with SSH from iOS, pairing, an install script for macOS and Linux, and jobs that survive the phone disconnecting. | 🟡 daemon in progress |
| M6 | **Computer use** | The macOS LaunchAgent can observe and act on the AX tree. The Jev decision loop with verification runs from the phone. First task: create a note in Notes. | ⬜ |
| M7 | **Live voice** | GPT-Live with client delegation, AirPods, barge-in, and working with the screen locked. Latency to first audio is measured. | ⬜ |
| M8 | **Hand-off and polish** | "Continue in Pi" on a hands host (the pi-phone pattern), a self/generations screen, docs. | ⬜ |
