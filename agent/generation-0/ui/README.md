# Mycroft's screen

Everything on Mycroft's screen is this folder: plain ES modules with Preact and htm, no build step. It runs in a
full-screen web view inside the app. When a generation that changes it is activated, the screen swaps to the new
code in place. Nothing is lost: conversations live in Pi Durable, and the screen's own state (navigation, drafts)
lives in a store that survives the swap.

## Files

| File | What it is |
|---|---|
| `index.html` | The page. Loads `style.css` (and any `<link data-hot>`) and `boot.js`. |
| `boot.js` | The link to the app, the two stores, and the hot swap. Changing it (or index.html) means a full page reload. |
| `app.js` | `mount(root, runtime)` / `unmount(root)`, the routes, the edge-swipe back, the theme report. |
| `lib.js` | Hooks (`useData`, `useUI`, `useCall`, `useNavigation`), markdown, formatting, icons, `Label`, `Tag`, `Spinner`, `Sheet`. |
| `screens/threads.js` | Home: the thread list (draft, pinned, active, the Settled shelf; swipe and long-press), sign-in, the new-thread button; the Archived screen. |
| `screens/thread.js` | A thread or a new thread's draft: transcript (user turns, finished runs folded into "Worked for", answers with Copy and Fork), the run capsule, the queue sheet, rename. |
| `screens/composer.js` | The composer: field with clear, dictation (hold, slide to cancel or lock, tap), send / queue / steer / stop. |
| `screens/settings.js` | Settings: sign-in, dictation model, queue or steer, keys, generations, machines, notices. |
| `screens/pair.js` | Adding a machine. |
| `style.css` | All styling. Colours are CSS variables in `:root` (`--accent`, `--accent-soft`, `--canvas`, `--raised`, `--ink`, `--ink-muted`, `--success`, `--danger`, `--warning`). |

Imports are relative (`./lib.js`) except the runtime: `import { html, render, useState, … } from '/lib/preact.js'`
(Preact + hooks + htm; also `useErrorBoundary`). Fonts: `JetBrains Mono` (labels, code, numbers) and
`Schibsted Grotesk` (prose). Add new files freely; new screens are new routes in `app.js`.

## Rules for changing it

1. Keep `app.js` exporting `mount(root, runtime)` and `unmount(root)`.
2. State that must survive a reload goes in the stores (`useUI` for the screen's own, `useData` for the app's), not
   only in `useState`.
3. Write complete files. Then use `self_preview` (optionally with a route) to see the draft at phone size. It also
   shows the errors it logged. Fix them before `self_activate`.
4. `self_activate` refuses a draft whose screen fails to render. If the new screen fails on the phone anyway, Mycroft
   goes back to the previous generation by itself.
5. Keep it a phone app: safe areas (`env(safe-area-inset-*)`), thumb-sized targets (≥ 40 px), `aria-label` on icon
   buttons, readable contrast on the dark canvas.
6. Motion: keep looping animations slow and seamless (the spinner turns once a second, the run glow takes 2.8 s and
   leaves both edges before it comes back). Under `prefers-reduced-motion`, swap slides and zooms for fades; never
   shorten an infinite animation's duration there, since it becomes a strobe.
7. Never send secrets or user data anywhere from the page. Links open in an in-app Safari sheet; the page can't
   navigate away.

## The runtime (`useRuntime()`)

- `call(op, args)` → Promise of the app's answer (rejects with its error message).
- `data`: the app's store: `{ state, views, listen, pairing }`. Use `useData((d) => …)`.
- `ui`: the screen's own store, saved in the app. Use `useUI(key, initial)`. `stack` (navigation), `drafts`
  (composer text by thread id; `new` is the new-thread draft), `whileWorking` (`'queue'` or `'steer'`) and
  `settledOpen` live here.
- `on(type, fn)`: raw events from the app.
- `generation`: the generation whose screen is running. `preview`: true in an off-screen check.

## Data from the app

`state` (sent again on every change):

```
{ phase: 'starting'|'ready'|'failed', failure?,
  generation: { active, lastGood, history: [{ generation, note, createdAt }] },
  threads: [{ id, title, createdAt, updatedAt, archived, machine?, pinned?, settledAt?, unsettledAt?,
             visitedAt?, finishedAt?, outcome?: 'done'|'failed'|'stopped', parent? }],   // newest first, not archived
  archived: [ …the same, archived ],
  busy: [threadId],                                 // threads with a run going
  signIn: { state: 'unknown'|'signedOut'|'signedIn'|'waiting'|'failed', code?, url?, message? },
  keys: { jev: bool },
  dictation: { engine: 'parakeet'|'apple', parakeet: bool },   // parakeet: this build bundles the model
  machines: [{ name, hostname, addresses, port, os, arch, version, pairedAt }],
  notices: [string], model: 'gpt-6.1-sol', screenErrors: [string] }
```

`views[threadId]`, after `call('thread.open', { id })` and until `thread.close`:

```
{ thread, busy, queued: [{ id, mode: 'followUp'|'steer', text }], model, error?,
  entries: [{ id, kind, model: [message] }],   // pi messages: role 'user' | 'assistant' | 'toolResult'
  live: { run?, generation?: { message }, tools: [{ callId, name, status, output }] } }
```

Assistant `content` blocks are `{ type: 'text', text }`, `{ type: 'thinking', thinking }` and
`{ type: 'toolCall', id, name, arguments }`. Tool results are `{ role: 'toolResult', toolCallId, toolName, content,
isError, durationMs }`, and their content may include `{ type: 'image', data, mimeType }`. `live.generation.message`
is the answer being written right now.

Other events:

- `listen`: the on-device dictation, for one composer at a time: `{ state: 'off'|'preparing'|'on'|'failed', owner,
  engine: 'parakeet'|'apple', loading, text, prefix, level, elapsed, error }`. `owner` is the id the composer started
  it with (a thread id as a string, or `'new'`), `text` what has been said and `prefix` the typed draft it goes after.
  With Parakeet, `text` updates every second or so and at each pause (Apple's word by word); `loading` is Parakeet
  still loading, while what is said is kept. Nothing is sent by the listener: `listen.stop` returns the words and the
  page sends them. It runs natively, so it goes on with the screen locked.
- `pairing`: `{ state: 'starting'|'waiting'|'paired'|'failed', command, pinned, copied, localNetwork, addresses: [{ network, ip }], chosen, machine?, message? }`. `addresses` are where a computer could reach the phone, nearest first; `network` is `Wi-Fi`, `Ethernet`, `Tailscale`, `NetBird`, `VPN`, `Personal Hotspot` or an interface name. `command` (short, on the clipboard) and `pinned` use the `chosen` one.

## Ops

| Op | Args | Does |
|---|---|---|
| `state.get` | | the `state` above |
| `thread.create` | `text` | starts a thread with its first message (a new thread is only a draft until then); returns `{ id, title, … }` |
| `thread.open` / `thread.close` | `id` | start / stop streaming `views[id]`; both mark the thread visited (its answer is read) |
| `thread.send` | `id, text, how?: 'queue'\|'steer'` | sends; while a run works, `queue` (default) waits for the run to end and `steer` reaches it at its next step |
| `thread.stop` | `id` | stops the run; queued messages stay, paused |
| `thread.resume` | `id` | sends the paused queue in order |
| `thread.unqueue` / `thread.steerNow` | `id, submission` | withdraws a queued message / hands it to the run now |
| `thread.fork` | `id, entry` | a new thread with the history up to and including `entry` (an answer), titled "Fork · …"; returns it |
| `thread.rename` | `id, title` | |
| `thread.pin` / `thread.settle` / `thread.archive` | `id, on` | settling unpins; sending to a thread unsettles it |
| `signin.start` / `signin.signOut` | | ChatGPT device-code sign-in; progress arrives in `state.signIn` |
| `signin.open` | `url, code?` | copies the code, opens the page in-app |
| `keys.save` | `name: 'jev', value` | empty value removes the key |
| `machines.check` | | `{ name: 'online' \| reason }` |
| `machines.forget` | `name` | |
| `pairing.start` / `pairing.stop` | `prefer?` (a network name) | install server for a new machine; `pairing` events |
| `pairing.choose` | `ip` | which address the commands use; the new command is copied |
| `listen.start` | `owner, prefix?` | dictate into the composer `owner`; `listen` events |
| `listen.stop` | | stop; returns `{ text }` (prefix and words), to send or edit |
| `listen.cancel` | | throw the words away and stop |
| `listen.clear` | | throw away the prefix and the words so far, and keep listening |
| `listen.close` | | stop everything (the screen went away) |
| `dictation.engine` | `engine: 'parakeet'\|'apple'` | the model dictation uses from the next start; in `state.dictation` |
| `generation.rollback` | `generation?` | switches Mycroft (agent and screen) to that generation |
| `clipboard.copy` | `text` | |
| `haptic` | `style: 'light'\|'medium'\|'success'\|'error'\|'selection'` | |
| `open.url` | `url` | opens an http(s) page in-app |
| `notices.thirdParty` | | the open source notices text |
| `ui.theme` | colours | tells the app the screen's colours (app.js does this on mount) |

`ui.boot`, `ui.ready`, `ui.failed`, `ui.hot`, `ui.save` and `ui.log` are boot.js's handshake with the app. Leave
them to boot.js.
