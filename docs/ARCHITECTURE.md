# Architecture

Mycroft splits an agent into a **brain** on the iPhone and **hands** on other machines. The brain owns everything that makes the agent *the agent*: the loop, the transcript, credentials, and its own source code. The hands only execute.

```
┌──────────────────────────── iPhone (iOS 27) ─────────────────────────────┐
│                                                                          │
│  Native host (Swift, signed, fixed)                                      │
│  ├─ WebUI: a WKWebView showing the active generation's ui/ (hot reload)  │
│  │         + WebBridge to the app; native recovery screen (shake)        │
│  ├─ RunController, RunMonitor: BGContinuedProcessingTask,                │
│  │         LongRunningIntent, Live Activity progress                     │
│  ├─ Listener, VoiceChat: dictation (Fluid Speech Mini), conversation     │
│  ├─ PiDurableKit: the JSContext, sqlite3, URLSession fetch/SSE           │
│  ├─ GenerationStore: generations on disk, drafts, activation, fallback   │
│  └─ Native tools: hands_* · Cua Driver's · show · self_* · code mode     │
│                                                                          │
│  Agent runtime (JavaScriptCore, replaceable)                             │
│  ├─ Pi Durable Harness: threads = conversations, tasks, docs, replay     │
│  ├─ extension.js: identity, style, JavaScript tools (the agent's own)    │
│  └─ Storage: SqliteStorage → native sqlite3                              │
│                                                                          │
│  Documents/ (file protection: until first unlock)                        │
│  ├─ mycroft.sqlite              durable state for every thread           │
│  └─ agent/generations/<n>/      extension.js + ui/: agent and screen     │
└─────────────────────────────────┬────────────────────────────────────────┘
                                  │ HTTPS (models) · TLS WebSocket (hands)
          ┌───────────────────────┼─────────────────────────┐
          ▼                       ▼                         ▼
   OpenAI (Sol 6.1 via      hands on Linux servers    hands on a Mac
   ChatGPT sub)             files · exec ·            + desktop control:
                            supervised jobs           Cua Driver
```

## 1. Runtimes on the phone and their boundaries

| Runtime | Language | Can change itself? | Lifetime |
|---|---|---|---|
| Native host | Swift | No. Changes need an Xcode build. | App process |
| Agent runtime | JavaScript in a `JSContext` | **Yes.** Loaded from `Documents/agent/generations/<active>`. | Replaced on every self-edit; state survives in SQLite |
| Screen | HTML/JS (Preact + htm) in a `WKWebView` | **Yes.** `ui/` of the active generation, served over `mycroft-ui://` | Hot-swapped on every self-edit; UI state and conversations survive |

**Why JavaScriptCore and not a WKWebView for the agent.** The spike (`spikes/background`) ran a `JSContext` in-process through 10+ minutes of background execution, including a self-edit and context swap. A WKWebView runs JS in a separate WebKit process that iOS throttles in the background. We give up WebKit's JIT; the agent is I/O-bound (model streaming, machines), so that is acceptable. [PiDurableKit](https://github.com/finnvoor/PiDurableKit) already proves Pi Durable runs on JavaScriptCore.

**Why the screen is web code.** At first it was SwiftUI, for real Liquid Glass, but compiled Swift can't change on the phone. Now everything on screen is the agent's own code in `ui/`, and it reloads in place like pim's "web > HMR". Liquid Glass is imitated in CSS. See [ADR 0009](decisions/0009-self-editable-web-ui.md). The agent itself stays in JavaScriptCore, where it keeps running in the background; the web view only renders.

## 2. Durable state

- One Pi Durable `Harness` over one SQLite database. Each **thread is a Pi conversation**, so forking, compaction, subagents and per-thread settings come from Pi Durable.
- The thread list and the paired machines are session-scoped Pi Durable documents (`mycroft.threads`, `mycroft.machines`), so the agent's tools and the screen read the same lists.
- Storage is Pi Durable's `SqliteStorage` over native `sqlite3`, both provided by [PiDurableKit](https://github.com/finnvoor/PiDurableKit).
- Files use `NSFileProtectionCompleteUntilFirstUserAuthentication` and keychain items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so a locked phone can keep working (the spike observed 53 s of work with protected data unavailable).

## 3. Models and auth

- Default: **Sol 6.1** (`openai-codex` provider, `gpt-6.1-sol`) on the ChatGPT subscription.
- Login: the OpenAI **device-code flow** that pi-ai already implements (`packages/ai/src/auth/oauth/openai-codex.ts`): show a code, the user approves at `auth.openai.com/codex/device`, tokens go to the keychain.
- Development: `DevImport` moves `~/.codex/auth.json`, dropped into the app's `Documents/import/` (`ios/scripts/dev-run.sh` for a Simulator), into the keychain. Production devices should use device login: sharing one refresh token between Codex and Mycroft makes them fight over refreshes.
- New threads use Sol 6.1 at high effort. There is no model picker; Apple's on-device model was tried (ADR 0016) and removed as too small to be useful.
- The JS runtime has no `fetch`. PiDurableKit provides one backed by `URLSession` with streaming bodies, so pi-ai's SSE streaming works unchanged.

## 4. Self-modification

See ADRs [0004](decisions/0004-self-modification-by-generations.md), [0009](decisions/0009-self-editable-web-ui.md) and [0015](decisions/0015-the-screen-calls-tools.md); the code is `GenerationStore` (`Agent/Generations.swift`) and the `self_*` tools (`Agent/SelfTools.swift`).

1. **Generations.** The agent's code is `extension.js` and `ui/`. Generation 0 is the app's bundled copy. `Documents/agent/generations/<n>/` holds only the files generation n changed; every other file comes from the app, so an app update reaches every generation. `SELF.md` and `ui/README.md` describe the app, so they always come from the app and the agent can't write them.
2. **Drafts.** `self_write` writes complete files into `Documents/agent/draft/`, which starts as a copy of the active generation; the running generation is never edited. `self_read` reads the draft (and pi-durable's docs), `self_diff` shows the change, and `self_preview` renders the draft's screen off-screen at the phone's size and returns a picture and the errors the page logged.
3. **Activation.** `self_activate { note }` first checks that a changed screen renders cleanly. Then `harness.install` replaces the extension named `mycroft` in the running harness: the current phase finishes on the old code, the next one runs the new, and the turn that made the edit continues. The draft becomes generation n+1, a child of the generation it started from, so after a rollback the next generation branches (Settings shows them as a tree). The web view swaps the changed modules in place. If the install fails, nothing changes; if the new screen fails on the phone, Mycroft goes back to the previous generation.
4. **Rollback.** `self_rollback` (and the screen's `generation.rollback`) re-activates an earlier generation, agent and screen. `self_status` lists the generations and the screen's recent errors.
5. **Fallback.** Each launch counts a boot; a generation that has run for 20 s with a working screen becomes the last good one. After 3 boots that never got there, or when the active generation's extension or screen fails to load, the host goes back to the last good generation and leaves a notice. Shaking the phone opens a native recovery screen.

There is no self-test and no scratch context: the screen check, `install` refusing a broken extension, and the fallback are the safety net. The agent writes plain JavaScript; nothing is compiled on the phone. This is Mario's "kill and respawn, pi durable takes care of the rest", made safe by generations and rollback. The native shell never needs a rebuild.

## 5. Long-running work

- Sending a message starts a **run**. The host submits a `BGContinuedProcessingTask` (title: thread name; progress: completed turns and tool calls) and keeps the Harness running when the app leaves the foreground.
- `LongRunningIntent` exposes "Ask Mycroft" to Shortcuts and Siri.
- If iOS ends the task, the run is simply interrupted. Pi Durable resumes it on the next launch or the next task.
- Evidence so far (iPhone 17 Pro Max, iOS 27.2): both APIs ran **over 10 minutes** in the background with progress; without progress reports one run was cancelled after ~58 s. Model streaming, battery and thermals are not yet measured.

## 6. Hands

`hands` is one small Rust binary for macOS and Linux. Details in [`hands/README.md`](../hands/README.md).

- **Pairing:** Add machine in Settings starts an install server on the phone (`InstallServer`); a one-line command on the computer downloads `hands` from it, installs the service and pairs back ([ADR 0008](decisions/0008-hands-transport-pairing.md), [`hands/docs/pairing.md`](../hands/docs/pairing.md)).
- **Transport:** the paired listener only: a WebSocket over TLS 1.3 to the machine, its certificate pinned, signed in with the phone's Ed25519 key from the keychain (`HandsConnection`). After the handshake each binary message is one request or reply. The protocol began as Pi's `pi-env` protocol (MIT), but `hands` no longer keeps compatibility with pi-env, and SSH (`hands serve --stdio`) is gone ([ADR 0019](decisions/0019-drop-pi-env-compat.md)).
- **Jobs:** a command that belongs to a connection dies with it, and the brain is a phone that sleeps. `hands` adds a **supervisor** (systemd user unit or LaunchAgent) that owns jobs keyed by the tool-call id. A job survives the phone disconnecting, and reattaching replays its output. Even `hands_exec` runs as a job, so a replayed call reattaches instead of running the command twice.
- **Tools** (`Hands/HandsTools.swift`): `hands_machines`, `hands_exec`, `hands_job_start`, `hands_job_wait`, `hands_job_cancel`, `hands_jobs`, `hands_read`, `hands_write`, `hands_edit` and `hands_list`. Each takes `machine`; the paired machines are listed in the system prompt.
- **Desktop control (macOS):** [Cua Driver](https://github.com/trycua/cua) (MIT) is linked into `hands` and runs in the supervisor that launchd starts, the one process macOS lets hold Accessibility and Screen Recording as "hands" ([ADR 0018](decisions/0018-computer-use-with-cua-driver.md)). `hands` forwards `cua.tools` (Cua's MCP tool list and instructions) and `cua.call` (one tool call, Cua's MCP result unchanged) to it over a Unix socket. Each client keeps one Cua session, so element tokens survive reconnects.
- **Computer use:** the phone's agent gets Cua's tools under their own names, descriptions and schemas, plus a `machine` property (`CuaTools.swift`; the catalog is bundled and refreshed from a Mac with a newer driver). Four core tools are always offered (`list_windows`, `launch_app`, `get_window_state`, `run_steps`, whose steps are the single actions); the rest load through `tool_search`, and Cua's instructions go into the system prompt. The model itself reads windows, acts and verifies. `hands` runs no model and never sees model credentials.

## 7. Trust model

The brain is trusted: the user's own agent on the user's own phone, with machines the user paired. A paired phone is shell access to that machine as the user who installed `hands`.

- `hands_exec`, `hands_write`, `hands_edit`, the `hands_job_*` tools and the `self_*` tools run without asking, by design. The prompt tells the agent to say what it will do and wait for a yes before something irreversible, but nothing enforces it. The screen's `tools.call` and `machines.exec` run the same way.
- Only Cua desktop actions are gated. A `beforeTool` hook stops one that looks irreversible (Cua marks the tool destructive, or it targets or types a word like delete, send, pay or quit) until the user agrees; the agent then repeats the call with `confirmed: true`.
- Self-modification is guarded against breakage, not against intent: see §4.

## 8. Voice

- Voice is part of every thread ([ADR 0010](decisions/0010-voice-in-every-thread.md)). One on-device listener serves the open composer: hold the mic to talk and release to send, or tap to keep it on; the user starts and stops it, and the screen sends the words like typed text ([ADR 0012](decisions/0012-threads-like-t3.md)). While a run works, a message queues for after it or steers it.
- The recognizer is Fluid Speech Mini, bundled in the app and run through FluidAudio on the Neural Engine; the turn is transcribed again every second and at each pause ([ADR 0014](decisions/0014-dictation-fluid-speech-mini.md), [0017](decisions/0017-fluid-speech-mini-only.md)). It loads when the app starts; audio heard before that is kept and transcribed once it has.
- The loop lives in the native host (`Listener`, `AVAudioSession` in play-and-record mode with no voice processing, and the `audio` background mode), so it runs with the screen locked, and a self-edit of the screen never drops it.
- A thread can also be a conversation ([ADR 0016](decisions/0016-conversation-mode.md)): `VoiceChat` listens hands-free with echo cancellation, sends each turn when the user pauses, and speaks each new sentence of the run's streaming text in Gradium's Phonon voice (bundled, through FluidAudio), so it talks while it works. Words that aren't its own echo cut it off.

## 9. Threads

- The agent can show as well as write: its `show` tool puts an image (one a tool returned, a file on a machine, or a URL) or its own HTML and CSS into the thread ([ADR 0013](decisions/0013-show-images-and-html.md)). Images ride on the tool result's `details`, which the model never sees again; HTML renders in a sandboxed frame without scripts or network.
- Each thread in the list holds its conversation id, title, times, pin, Settled and archive state, how its last run ended, and the thread it was forked from.
- The infinite chat ([ADR 0020](decisions/0020-infinite-chat.md)), after UniiChat: one thread that never ends, opened from "Mycroft ∞" above the list. Over its messages grows a binary tree of one-line summaries, built in the background and kept in `Documents/memory/` (`Agent/Memory.swift`); each request sees a view of that tree (detail fading with age) and the current run whole, and `memory_zoom` opens a line into the two it was made from, down to the message.
- A thread is not bound to a machine: every hands and desktop tool takes `machine`, and the agent picks one per call, several at once if it likes. A per-thread execution environment (Pi Durable example 29, Mario's "Hetzner trick") is not built.

## Known risks

- **Locked-screen continuity:** observed for 53 s, not for whole runs.
- **No published runtime limit:** Apple publishes no `BGContinuedProcessingTask` limit. Apple DTS says runs over an hour are possible but not guaranteed.
- **Unverified on-device pieces:** Pi Durable's bundle size and JSC startup time on device.
- **Refresh-token rotation:** if `auth.json` is shared between Codex and Mycroft, they can invalidate each other's tokens.
- **App Store guideline 2.5.2 forbids apps that change their own code.** Mycroft targets personal installs signed in Xcode, not the App Store.
