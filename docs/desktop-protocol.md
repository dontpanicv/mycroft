# Desktop control protocol (`ui.observe`, `ui.act`, `ui.screenshot`)

How Mycroft drives a Mac's apps. The design follows [jev-use](https://github.com/savka777/jev-use) (MIT): read the
Accessibility tree, have Jev pick the next operation and its target, act, then read again to check. The loop needs no
pixels; `ui.screenshot` exists for the times the phone has to look at the screen itself.

```
phone (brain)                    Mac
desktop_do ─ ui.observe ──► hands ──► Mycroft Hands.app (LaunchAgent in the GUI session; Accessibility, Screen Recording)
   │  ◄── elements, apps, menus ─┘
   ├─ Jev (api.typesafe.ai, key stays on the phone) → operation + target
   └─ ui.act ──► hands ──► hands-desktop → performs it → result, screenChanged
```

## Transport

- **Phone → `hands`:** pi-env request frames `ui.observe`, `ui.act` and `ui.screenshot`, carrying the JSON below. They are listed in `hello.features` while a desktop helper answers `ping` (`hands` caches the answer for 3 s).
- **`hands` → helper:** newline-delimited JSON over the Unix socket `desktop.sock` in hands' state directory (mode 0600). Each line is one request `{ "id", "op", ...fields }` and gets one response line `{ "id", "ok": true, ...result }` or `{ "id", "ok": false, "error": { "code", "message" } }`. `hands` opens one connection per request, so concurrent requests never share one; the helper runs them one at a time.
- **Results:** `hands` returns the helper's result fields, without `id` and `ok`, as the result frame's JSON. For `ui.screenshot` it decodes `png` into the frame's raw payload (below).
- **Errors:** the helper's `code` and `message` become the pi-env error frame's `code` and `message`.

  | code | meaning |
  |---|---|
  | `not_trusted` | the helper lacks Accessibility permission (`ui.observe`, `ui.act`). The message tells the user where to grant it. |
  | `not_permitted` | the helper lacks Screen Recording permission (`ui.screenshot`). The message tells the user where to grant it. |
  | `stale` | the `observation` is outdated |
  | `not_found` | unknown ref or app |
  | `invalid` | bad request |
  | `failed` | the action failed; the message says why |
  | `not_supported` | from `hands` itself: no helper answers (Linux, no GUI session, or the helper is not installed) |
  | `aborted` | from `hands` itself: the phone cancelled the request |

  `hands` reports a helper that hangs up, times out (60 s) or sends something unreadable as `failed`.

### `ping` (socket only)

`{ "id", "op": "ping" }` → `{ "trusted": bool, "screenRecording": bool, "version": "0.2.0" }`. `trusted` is
Accessibility. A helper before 0.2.0 omits `screenRecording`, and `hands` reads that as `false`. `hands` uses `ping`
for `hello.features`, `hands doctor` and `hands desktop permissions`; the phone never sends it.

## `ui.observe { app?, maxElements? }`

`app` is a bundle id or a name; without it, the frontmost app is read. `maxElements` defaults to 150.

The helper walks the app's focused window, plus its menu bar for `available.menus`, and returns:

```json
{
  "observation": "o-17",
  "application": "Notes",
  "bundleId": "com.apple.Notes",
  "window": "Shopping list",
  "otherWindows": 2,
  "elements": [
    { "ref": "e1", "index": 1, "role": "button", "label": "New Note", "value": null, "place": "toolbar", "operations": ["press"] },
    { "ref": "e2", "index": 2, "role": "text area", "label": "Note body", "value": "Milk", "place": "content", "operations": ["type", "focus"] }
  ],
  "available": {
    "apps": ["Notes", "Safari", "Terminal"],
    "folders": ["Desktop", "Documents", "Downloads"],
    "sites": [],
    "menus": ["File > New Note", "Format > Bold"]
  },
  "secureInputActive": false
}
```

- `index` is the element's screen order, 1-based, top to bottom then left to right.
- `place` is one of `toolbar`, `sidebar`, `content`, `dialog`, `menu`. Treat it as a hint.
- `operations` lists which of `press`, `select`, `click`, `focus` and `type` the element supports.
- Secure text fields are left out entirely. `secureInputActive` is true while one has focus.
- `refs` are valid only for this `observation`.
- `available.apps` holds running apps plus apps in /Applications, up to 200. `available.menus` holds the frontmost app's enabled menu items as `Menu > Item` paths, up to 300.

## `ui.act { observation, operation, ... }`

| operation | fields | does |
|---|---|---|
| `OPEN_APP` | `app` | launches the app or brings it to the front |
| `QUIT_APP` | `app` | quits it normally, never forced |
| `OPEN_URL` | `url` | opens the URL in the default browser |
| `OPEN_FOLDER` | `path` | reveals the folder in Finder. `~` is home; also accepts Desktop, Documents, Downloads |
| `PRESS` | `ref` | AXPress, or AXConfirm or AXPick when PRESS isn't supported |
| `SELECT` | `ref` | selects a row, tab or item (AXSelected) |
| `CLICK` | `ref` | a synthetic mouse click at the element's centre |
| `FOCUS` | `ref` | focuses an input |
| `TYPE_TEXT` | `text`, `ref?` | focuses `ref` if given, then types `text` (unicode key events) |
| `PRESS_KEY` | `key`, `modifiers?`, `times?` | `key`: `return`, `escape`, `tab`, `space`, `delete`, `up`, `down`, `left`, `right`, `pageup`, `pagedown`, a single character, or `f1`…`f12`. `modifiers` from `cmd`, `shift`, `option`, `control`. `times` defaults to 1 |
| `SCROLL` | `direction` (`up`/`down`), `times?` | scrolls the focused window by one screen per time |
| `MENU` | `menu` | presses the `Menu > Item` path |

The response is `{ "result": "Pressed “New Note” in Notes", "screenChanged": true }`. `screenChanged` compares a fingerprint of the focused window's elements taken before and after the action, about 250 ms apart.

## `ui.screenshot { display?, maxWidth? }`

Captures a display with ScreenCaptureKit (`SCScreenshotManager`), the pointer included. Needs **Screen Recording**, not
Accessibility; without it the answer is `not_permitted` (checked with `CGPreflightScreenCaptureAccess`, which never
prompts). It does not touch the current observation.

| field | default | |
|---|---|---|
| `display` | `"main"` | `main` is the display with the menu bar, and the only one supported. Anything else is `invalid`. |
| `maxWidth` | `1600` | 1-8192. The image is the display's native pixels, scaled down (never up) to at most this width, keeping the aspect ratio. |

- **Pi-env frame (phone ← `hands`):** the JSON is `{ "width": 1600, "height": 1034 }`, the image's size in pixels, and
  the frame's payload is the PNG file's raw bytes. A PNG larger than a frame's payload (16 MiB less 64 KiB) is
  `failed`; ask again with a smaller `maxWidth`.
- **Socket (`hands` ← helper):** the same fields plus `png`, the PNG in standard base64 with padding:
  `{ "id", "ok": true, "png": "iVBORw0KGgo…", "width": 1600, "height": 1034 }`.

## Safety

- The helper performs only the operations above. It never runs shell commands; that is the job of `hands` exec and jobs.
- No secure text is read or typed. A screenshot is taken only for an explicit `ui.screenshot` and goes only to the
  requesting connection; the helper never stores one.
- The phone stops and asks the user before destructive picks such as quitting apps, delete buttons, Send, Pay or Buy. That is phone policy and is applied before `ui.act`.

## Permissions

The helper is **Mycroft Hands.app** (bundle id `dev.mycroft.hands-desktop`, no Dock icon), installed by `hands install`
to `~/Applications` and run by the LaunchAgent `dev.mycroft.hands-desktop`. It needs two permissions, which only the
user can grant: **Accessibility** for `ui.observe` and `ui.act`, and **Screen Recording** for `ui.screenshot`.

- macOS asks for, and grants, both to the *responsible* app of a process. That is Mycroft Hands when launchd starts it
  (the LaunchAgent, or `open`), but the terminal app when a binary is run from a shell. So the prompts are always
  shown by the app itself: `open -n "Mycroft Hands.app" --args --request-permissions`.
- The request flow asks for one at a time: `AXIsProcessTrustedWithOptions` with the prompt option and System Settings
  at `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`, then, once that is granted,
  `CGRequestScreenCaptureAccess` and `?Privacy_ScreenCapture` (`--only` asks for one alone). It polls until each is
  granted or its wait runs out, then restarts the serving helper, since a process sees a new Screen Recording grant
  only after a restart.
- TCC keys both grants to the bundle id and the signing team, so they survive updates signed by the same team. An
  ad-hoc signed build is keyed to that exact build and needs both again after every rebuild.
- `hands desktop permissions` reports what the running helper has; `--request` runs the flow above and waits.
