# Desktop control protocol (`ui.observe`, `ui.act`)

How Mycroft drives a Mac's apps without screenshots. The design follows [jev-use](https://github.com/savka777/jev-use)
(MIT): read the Accessibility tree, have Jev pick the next operation and its target, act, then read again to check.

```
phone (brain)                    Mac
desktop_do ─ ui.observe ──► hands ──► hands-desktop (LaunchAgent in the GUI session, has Accessibility permission)
   │  ◄── elements, apps, menus ─┘
   ├─ Jev (api.typesafe.ai, key stays on the phone) → operation + target
   └─ ui.act ──► hands ──► hands-desktop → performs it → result, screenChanged
```

## Transport

- **Phone → `hands`:** pi-env request frames `ui.observe` and `ui.act`, carrying the JSON below. They are listed in `hello.features` when a desktop helper is reachable.
- **`hands` → `hands-desktop`:** newline-delimited JSON over the Unix socket `desktop.sock` in hands' state directory (mode 0600). Each line is one request `{ "id", "op", ...fields }` and gets one response line `{ "id", "ok": true, ...result }` or `{ "id", "ok": false, "error": { "code", "message" } }`.
- **Errors:**

  | code | meaning |
  |---|---|
  | `not_trusted` | the helper lacks Accessibility permission. The message tells the user where to grant it. |
  | `stale` | the `observation` is outdated |
  | `not_found` | unknown ref or app |
  | `invalid` | bad request |
  | `failed` | the action failed; the message says why |
  | `not_supported` | `hands` couldn't reach a helper (Linux, or no GUI session) |

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

## Safety

- The helper performs only the operations above. It never runs shell commands; that is the job of `hands` exec and jobs.
- No screenshots, and no secure text is read or typed.
- The phone stops and asks the user before destructive picks such as quitting apps, delete buttons, Send, Pay or Buy. That is phone policy and is applied before `ui.act`.
