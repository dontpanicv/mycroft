# Mycroft

A self-modifying, durable agent that lives on your iPhone.

Mycroft's **brain** runs on the phone: the agent loop, conversation state, model credentials and its own source code. Its **hands** run on your Macs and Linux servers: shells, files, long-running jobs, and desktop control. The agent can edit its own JavaScript on the device, hot-reload, and resume the turn that made the edit, because every step is committed to durable storage before it is shown.

The design builds on Mario Zechner's "pim" ([Pi Durable](https://github.com/earendil-works/pi/tree/main/packages/durable) on an Android phone) and adapts it to what iOS 27 does and doesn't allow. See [docs/research](docs/research/) for how we got here.

> Status: **pre-alpha, built in public.** Nothing here is a product yet. See [docs/ROADMAP.md](docs/ROADMAP.md).

## What it will do

- **Threads.** Multiple parallel conversations, each a durable Pi conversation with its own model, tools and execution environment.
- **Talk or type, in any thread.** Hold the mic and let go to send, or tap it and pause. Answers can be read aloud while Mycroft keeps listening, and talking interrupts. Speech is recognized on the iPhone itself ([ADR 0010](docs/decisions/0010-voice-in-every-thread.md)).
- **ChatGPT subscription login.** Default model **Sol 6.1** via the `openai-codex` provider, signed in with the device-code flow (the same login Codex uses). Any other Pi provider can be selected per thread.
- **Self-modification, screen included.** The agent's code (its behaviour in `extension.js`, and the whole screen in `ui/`, web code with Preact) lives in the app's Documents folder, not the signed bundle. The agent edits it, previews the screen off-screen, and activates it. The runtime swaps the code, the screen hot-reloads in place, and Pi Durable carries on. Known-good generations are kept for rollback.
- **Long-running background work.** User-started runs continue after you leave the app via `BGContinuedProcessingTask` and `LongRunningIntent` (both measured above 10 minutes on an iPhone with iOS 27.2; see the spike).
- **Hands.** A small daemon for macOS and Linux (`hands/`). It gives the phone files, shell, PTY, supervised jobs that survive the phone going offline, and on macOS, Accessibility-tree desktop control driven by the Jev system-one model.

## Layout

| Path | What |
|---|---|
| [`ios/`](ios/) | Native iOS 27 host: the web view that shows the agent's own screen, JavaScript runtime host, bridges (SQLite, files, keychain, network, audio), background-task controller. |
| [`agent/`](agent/) | TypeScript agent that runs inside the host: Pi Durable harness, extensions (hands tools, computer use, self-edit), and the threads UI. |
| [`hands/`](hands/) | The `hands` daemon for macOS and Linux. |
| [`docs/`](docs/) | Architecture, decisions, design direction, research. |
| [`spikes/`](spikes/) | Throwaway experiments that produced evidence for the design. |

## Docs

- [Architecture](docs/ARCHITECTURE.md)
- [Roadmap](docs/ROADMAP.md)
- [Design direction](docs/DESIGN.md)
- [Decisions](docs/decisions/)
- [Research](docs/research/README.md)

## Credits

- [Pi / Pi Durable / pi-env](https://github.com/earendil-works/pi) by Mario Zechner, Armin Ronacher and Earendil (MIT)
- [PiDurableKit](https://github.com/finnvoor/PiDurableKit) (CC0) for showing Pi Durable on JavaScriptCore
- [pi-phone](https://github.com/picassio/pi-phone) (MIT) for the Pi session hand-off pattern
- [pi-computer-use](https://github.com/injaneity/pi-computer-use) (MIT) and [jev-use](https://github.com/savka777/jev-use) for the Accessibility → Jev → act → verify loop

## License

MIT
