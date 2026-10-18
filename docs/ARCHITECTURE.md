# Architecture

Mycroft splits an agent into a **brain** on the iPhone and **hands** on other machines. The brain owns everything that makes the agent *the agent*: the loop, the transcript, credentials, and its own source code. The hands only execute.

```
┌──────────────────────────── iPhone (iOS 27) ─────────────────────────────┐
│                                                                          │
│  Native host (Swift, signed, fixed)                                      │
│  ├─ SwiftUI shell: threads, chat, voice, settings (Liquid Glass)         │
│  ├─ RunController: BGContinuedProcessingTask / LongRunningIntent,        │
│  │                 Live Activity progress, stall reporting               │
│  ├─ VoiceSession: GPT-Live (client delegation), AVAudioSession, AirPods  │
│  ├─ Bridges: SQLite · files · keychain · URLSession fetch/SSE · SSH      │
│  └─ RuntimeHost: owns the JSContext, loads the active generation,        │
│                  swaps it on self-edit, rolls back on crash loops        │
│                                                                          │
│  Agent runtime (JavaScriptCore, replaceable)                             │
│  ├─ Pi Durable Harness: threads = conversations, tasks, docs, replay     │
│  ├─ Extensions: hands tools · computer use (Jev) · self-edit · voice     │
│  └─ Storage: SqliteStorage → native sqlite3 via bridge                   │
│                                                                          │
│  Documents/ (file protection: until first unlock)                        │
│  ├─ mycroft.sqlite              durable state for every thread           │
│  └─ agent/generations/<n>/      agent source the agent may edit          │
└─────────────────────────────────┬────────────────────────────────────────┘
                                  │ HTTPS (models) · SSH (hands)
          ┌───────────────────────┼─────────────────────────┐
          ▼                       ▼                         ▼
   OpenAI (Sol 6.1 via      hands on Linux servers    hands on a Mac
   ChatGPT sub) · GPT-Live  files · exec · PTY ·      + desktop agent:
   · Jev (typesafe.ai)      supervised jobs           AX observe / act
```

## 1. Runtimes on the phone and their boundaries

| Runtime | Language | Can change itself? | Lifetime |
|---|---|---|---|
| Native host | Swift | No. Changes need an Xcode build. | App process |
| Agent runtime | JavaScript in a `JSContext` | **Yes.** Loaded from `Documents/agent/generations/<active>`. | Replaced on every self-edit; state survives in SQLite |
| Message canvas (later) | HTML/JS in a `WKWebView` | Yes, artifacts and custom renderers | Per view |

**Why JavaScriptCore and not a WKWebView for the agent.** The spike (`spikes/background`) ran a `JSContext` in-process through 10+ minutes of background execution, including a self-edit and context swap. A WKWebView runs JS in a separate WebKit process that iOS throttles in the background. We give up WebKit's JIT; the agent is I/O-bound (model streaming, SSH), so that is acceptable. [PiDurableKit](https://github.com/finnvoor/PiDurableKit) already proves Pi Durable runs on JavaScriptCore.

**Why the shell UI is SwiftUI.** Liquid Glass is a native material (`glassEffect`). The thread list, composer and voice surface stay native. Agent-authored UI (artifacts, renderers) goes into a web canvas inside a message, which the agent *can* modify.

## 2. Durable state

- One Pi Durable `Harness` over one SQLite database. Each **thread is a Pi conversation**, so forking, compaction, subagents and per-thread settings come from Pi Durable.
- Storage is Pi Durable's `SqliteStorage` over its `SqliteDatabase` facade (`exec`, `run`, `get`, `all`, `transaction`, `close`), implemented by a native bridge to `sqlite3`. It must pass Pi Durable's storage conformance suite in the simulator.
- Files use `NSFileProtectionCompleteUntilFirstUserAuthentication` and keychain items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so a locked phone can keep working (the spike observed 53 s of work with protected data unavailable).

## 3. Models and auth

- Default: **Sol 6.1** (`openai-codex` provider, `gpt-6.1-sol`) on the ChatGPT subscription.
- Login: the OpenAI **device-code flow** that pi-ai already implements (`packages/ai/src/auth/oauth/openai-codex.ts`): show a code, the user approves at `auth.openai.com/codex/device`, tokens go to the keychain.
- Development: `scripts/import-codex-auth` copies `~/.codex/auth.json` into a simulator build. Production devices should use device login: sharing one refresh token between Codex and Mycroft makes them fight over refreshes.
- Every Pi provider stays selectable per thread.
- The JS runtime has no `fetch`. The host provides one backed by `URLSession` with streaming bodies, so pi-ai's SSE streaming works unchanged.

## 4. Self-modification

1. The agent's source lives in `Documents/agent/generations/<n>/`. Generation 0 is copied from the app bundle on first launch.
2. Self-edit tools (`self.read`, `self.edit`, `self.test`, `self.activate`) let the agent change a **new** generation, never the running one.
3. `self.activate` loads the candidate in a scratch `JSContext` and runs its self-test. On success the host atomically flips `active`, checkpoints, swaps the main context and resumes the Harness. Pi Durable rebinds extensions by name, and the turn that made the edit continues.
4. If a generation fails to boot or crash-loops (N failures in T seconds), the host rolls back to the last good generation and tells the agent why.
5. TypeScript is stripped on-device by a pure-JS type stripper (no WASM, no JIT required). Open question: the module format and bundler (ADR 0004).

This is Mario's "kill and respawn, pi durable takes care of the rest", made safe by the generation and rollback scheme. The native shell never needs a rebuild.

## 5. Long-running work

- Sending a message starts a **run**. The host submits a `BGContinuedProcessingTask` (title: thread name; progress: completed turns and tool calls) and keeps the Harness running when the app leaves the foreground.
- `LongRunningIntent` exposes "Ask Mycroft" to Shortcuts and Siri.
- If iOS ends the task, the run is simply interrupted. Pi Durable resumes it on the next launch or the next task.
- Evidence so far (iPhone 17 Pro Max, iOS 27.2): both APIs ran **over 10 minutes** in the background with progress; without progress reports one run was cancelled after ~58 s. Model streaming, battery and thermals are not yet measured.

## 6. Hands

`hands` is one small Rust binary for macOS and Linux. Details in [`hands/README.md`](../hands/README.md).

- **Transport:** SSH from the phone, then `hands serve --stdio`. The wire protocol is a superset of Pi's `pi-env` protocol (MIT), so its file, exec, PTY and `listFiles` semantics carry over.
- **Jobs:** pi-env kills child processes when the connection drops (30 s idle). That doesn't work when the brain is a phone that sleeps. `hands` adds a **supervisor** (systemd user unit or LaunchAgent) that owns jobs keyed by the tool-call id. A job survives the phone disconnecting, and reattaching replays its output, so "start job" becomes a replay-safe tool.
- **Desktop control (macOS):** SSH sessions can't get Accessibility (TCC) permission, so `hands` installs a LaunchAgent in the logged-in user session. The SSH-side process proxies `ui.observe` and `ui.act` calls to it over a Unix socket.
- **Computer-use loop:** observe the AX tree → compact element list with refs → **Jev** (typesafe.ai) picks the operation *and* target in one request (the jev-use pattern) → `hands` acts → re-observe to verify. The Jev key stays on the phone (brain), and `hands` never sees model credentials.

## 7. Voice

- GPT-Live with **client delegation**: the live model handles the conversation and hands real work to Pi Durable through a function call. Each call becomes a durable submission whose `requestId` is the call id, so retries are deduplicated. Progress streams back as context.
- Barge-in maps to Pi's steer and cancel.
- Audio lives in the native host (`VoiceSession`, `AVAudioSession` in play-and-record mode with the `audio` background mode), so a JS self-reload never drops the call.

## 8. Threads

- The thread list is a session-scoped document. Each thread holds a conversation id, title, model, execution environment (phone-only, or a named `hands` host) and pin/archive state.
- The environment is resolved per tool call from the thread's document (Pi Durable example 29), so a thread can move between machines mid-conversation (Mario's "Hetzner trick").

## Known risks

- **Locked-screen continuity:** observed for 53 s, not for whole runs.
- **No published runtime limit:** Apple publishes no `BGContinuedProcessingTask` limit. Apple DTS says runs over an hour are possible but not guaranteed.
- **Unverified on-device pieces:** Pi Durable's bundle size and JSC startup time on device, and on-device TypeScript stripping.
- **Refresh-token rotation:** if `auth.json` is shared between Codex and Mycroft, they can invalidate each other's tokens.
- **App Store guideline 2.5.2 forbids apps that change their own code.** Mycroft targets personal installs signed in Xcode, not the App Store.
