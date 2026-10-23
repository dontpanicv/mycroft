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

Mycroft stands on other people's work. Thank you.

**The idea.** Mario Zechner ([@badlogicgames](https://x.com/badlogicgames)) ran Pi Durable on an Android phone ("pim"): the brain on the phone, the hands elsewhere, an agent that edits itself. Mycroft is that idea brought to iOS ([research](docs/research/README.md)).

**Built on**

- [Pi, Pi Durable and pi-env](https://github.com/earendil-works/pi) (MIT) by Mario Zechner, Armin Ronacher ([@mitsuhiko](https://x.com/mitsuhiko)) and Earendil ([@earendilworks](https://x.com/earendilworks)). The agent runs on Pi Durable, and `hands` is built on the pi-env daemon ([NOTICE](hands/NOTICE)).
- [PiDurableKit](https://github.com/finnvoor/PiDurableKit) (CC0) by Finn Voorhees: Pi Durable on JavaScriptCore, the app's runtime.
- [Cua Driver](https://github.com/trycua/cua) (MIT) by Cua ([@trycua](https://x.com/trycua)), linked into `hands` for desktop control.
- [Fluid Speech Mini](https://huggingface.co/FluidVoice-Labs/fluid-speech-mini-coreml) (CC-BY-4.0) by FluidVoice ([@FluidVoiceApp](https://x.com/FluidVoiceApp)) for dictation, built on NVIDIA's Parakeet TDT 0.6B v3 and Moondream's Parakeet Ultra.
- [Phonon 31m](https://huggingface.co/gradium/phonon-31m-en) (Apache-2.0) by Gradium ([@GradiumAI](https://x.com/GradiumAI)), Mycroft's voice in a conversation. Jon Taylor ([@JonPTaylor](https://x.com/JonPTaylor)) pointed us to it.
- [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0) and the [Core ML conversions](https://huggingface.co/FluidInference/pocket-tts-coreml) by FluidInference, which run both speech models on the Neural Engine.
- [Preact](https://preactjs.com) (MIT) and [htm](https://github.com/developit/htm) (Apache-2.0) for the agent's screen; [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) and [Schibsted Grotesk](https://github.com/schibsted/schibsted-grotesk) (SIL OFL) for its type ([licenses](docs/licenses/)).

**Ideas taken from**

- [UniiChat](https://github.com/VictorTaelin/UniiChat) (Apache-2.0) by Victor Taelin: the memory tree behind Mycroft ∞, the infinite chat ([ADR 0020](docs/decisions/0020-infinite-chat.md)).
- [T3 Code](https://github.com/pingdotgg/t3code) (MIT) by Ping.gg: how threads work, with drafts, queue or steer, and fork ([ADR 0012](docs/decisions/0012-threads-like-t3.md)).
- [pi-phone](https://github.com/picassio/pi-phone) (MIT) by Picassio ([@ocbieuvang](https://x.com/ocbieuvang)): handing a session off to Pi on a server.
- [grep.ai](https://grep.ai/) and iOS 27's Liquid Glass: the visual style ([design direction](docs/DESIGN.md)).
- Computer use before Cua ([ADR 0006](docs/decisions/0006-computer-use-with-jev.md), since replaced), which shaped the design: [jev-use](https://github.com/savka777/jev-use) by sav ([@savboj](https://x.com/savboj)), [Computah](https://github.com/musubipapi/computah) by Andy Gao ([@instantricecook](https://x.com/instantricecook)), [Jev](https://docs.typesafe.ai/) by typesafe.ai ([@typesafeai](https://x.com/typesafeai)) and [pi-computer-use](https://github.com/injaneity/pi-computer-use) by injaneity.
- Rui Carmo ([@rcarmo](https://x.com/rcarmo)), whose Pi-on-iPhone report and [ios-linuxkit](https://github.com/rcarmo/ios-linuxkit) answered "can this run on iOS?", and Underdog's Bark 3.0, the first dictation model we built and measured ([ADR 0014](docs/decisions/0014-dictation-fluid-speech-mini.md)).

The name is Mycroft Holmes, the brother who stays in his armchair while others do the legwork, and a nod to Mike in Heinlein's *The Moon Is a Harsh Mistress*.

## License

MIT
