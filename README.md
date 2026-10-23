# Mycroft

A self-modifying, durable agent that lives on your iPhone.

Mycroft's **brain** runs on the phone: the agent loop, conversation state, model credentials and its own source code. Its **hands** run on your Macs and Linux servers: shells, files, long-running jobs, and desktop control. The agent can edit its own JavaScript on the device, hot-reload, and resume the turn that made the edit, because every step is committed to durable storage before it is shown.

The design builds on Mario Zechner's "pim" ([Pi Durable](https://github.com/earendil-works/pi/tree/main/packages/durable) on an Android phone) and adapts it to what iOS 27 does and doesn't allow. See [docs/research](docs/research/) for how we got here.

> Status: **pre-alpha, built in public.** Nothing here is a product yet. See [docs/ROADMAP.md](docs/ROADMAP.md).

## What it will do

- **Threads.** Multiple parallel conversations, each a durable Pi conversation. Any thread can use any paired machine, several at once.
- **Talk or type, in any thread.** Hold the mic and let go to send, or tap it to keep it on; you start and stop it. While Mycroft works, messages queue or steer the run. Speech is recognized on the iPhone itself, by Fluid Speech Mini bundled in the app ([ADR 0010](docs/decisions/0010-voice-in-every-thread.md), [0012](docs/decisions/0012-threads-like-t3.md), [0014](docs/decisions/0014-dictation-fluid-speech-mini.md), [0017](docs/decisions/0017-fluid-speech-mini-only.md)).
- **Or have a conversation.** The wave next to the mic turns a thread into a hands-free conversation: Mycroft answers aloud in Gradium's Phonon voice, on the iPhone, and says what it's doing while it works. Talk over it to cut in; end it and the thread carries on ([ADR 0016](docs/decisions/0016-conversation-mode.md)).
- **ChatGPT subscription login.** Default model **Sol 6.1** via the `openai-codex` provider, signed in with the device-code flow (the same login Codex uses).
- **Self-modification, screen included.** The agent's code (its behaviour in `extension.js`, and the whole screen in `ui/`, web code with Preact) lives in the app's Documents folder, not the signed bundle. The agent edits it, previews the screen off-screen, and activates it. The runtime swaps the code, the screen hot-reloads in place, and Pi Durable carries on. Known-good generations are kept for rollback. The screen can call every tool the agent has, so a new screen feature that needs data from machines needs no app update ([ADR 0015](docs/decisions/0015-the-screen-calls-tools.md)).
- **Long-running background work.** User-started runs continue after you leave the app via `BGContinuedProcessingTask` and `LongRunningIntent` (both measured above 10 minutes on an iPhone with iOS 27.2; see the spike).
- **Hands.** A small daemon for macOS and Linux (`hands/`). Paired with the phone over a pinned TLS WebSocket, it gives the agent files, shell, supervised jobs that survive the phone going offline, and on macOS desktop control: [Cua Driver](https://github.com/trycua/cua) is linked into `hands`, and the phone's agent uses Cua's tools directly, asking you before risky actions such as deleting, sending or paying ([ADR 0018](docs/decisions/0018-computer-use-with-cua-driver.md)).

## Layout

| Path | What |
|---|---|
| [`ios/`](ios/) | Native iOS 27 host: the web view that shows the agent's own screen, the JavaScriptCore runtime (PiDurableKit), native tools (hands, desktop control, show, self-edit), voice, background-task controller. |
| [`agent/`](agent/) | The agent's own code as shipped (generation 0), which it rewrites on the phone: `extension.js` (identity, style, JavaScript tools) and `ui/`, the whole screen. |
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
- [Cua Driver](https://github.com/trycua/cua) by Cua (MIT), linked into `hands` for desktop control

## License

MIT
