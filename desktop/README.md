# hands-desktop

The macOS desktop-control helper of Mycroft's [`hands`](../hands/README.md) daemon. It runs in the logged-in user's
GUI session with Accessibility permission, reads the Accessibility (AX) tree of the app in front, and performs UI
actions. `hands` cannot do this itself: a process started over SSH never gets Accessibility permission. So `hands`
proxies `ui.observe` and `ui.act` to this helper over a Unix socket.

The contract is [docs/desktop-protocol.md](../docs/desktop-protocol.md); the loop around it is
[ADR 0006](../docs/decisions/0006-computer-use-with-jev.md). The reading and acting code is ported from
[jev-use](https://github.com/savka777/jev-use) (MIT); see [NOTICE](NOTICE).

No screenshots are taken, no shell commands are run, and no secure text is read or typed.

## Build and test

```sh
swift build                 # debug build: .build/debug/hands-desktop
swift test                  # no Accessibility needed; a fake backend stands in for AX
./scripts/build.sh          # universal (arm64 + x86_64) release binary in dist/hands-desktop
```

Swift 6, macOS 14 or later. `DesktopCore` holds everything (the JSON contract, request dispatch, the socket server and
the AX backend behind the `DesktopBackend` protocol); the `hands-desktop` executable is a thin CLI over it. The tests
never perform real UI actions. One read-only test observes the frontmost app, and it runs only when the test process
is already trusted for Accessibility.

## Permission

hands-desktop needs **Accessibility** (System Settings > Privacy & Security > Accessibility). Only the user can grant
it; the helper never changes privacy settings itself.

```sh
hands-desktop doctor              # is Accessibility granted? how to grant it (exit 0 when granted)
hands-desktop request-permission  # makes macOS show its own permission dialog
```

macOS ties the grant to the process that macOS holds responsible. Started by the LaunchAgent, that is the
hands-desktop binary itself. Started from a terminal, it is the terminal app. The grant also follows the code
signature: `scripts/build.sh` signs ad hoc with the identifier `dev.mycroft.hands-desktop`, so a rebuilt binary must
be granted again. Set `CODESIGN_IDENTITY` to a Developer ID to keep the grant across updates.

Without the grant the helper still serves: `ping` answers, and `ui.observe` and `ui.act` return `not_trusted` with
instructions.

## The socket

`hands-desktop serve [--socket PATH]` listens on a Unix domain socket:

- The default path is `$HANDS_STATE_DIR/desktop.sock`, else `~/Library/Application Support/hands/desktop.sock`.
  `hands` resolves its state directory the same way.
- The socket has mode 0600. A missing parent directory is created with mode 0700. A leftover socket file is replaced.
  If another helper is listening there, `serve` exits with an error.
- The wire format is newline-delimited JSON, one request per line and one response line each. Requests are
  `{ "id", "op", ...fields }`. Responses are `{ "id", "ok": true, ...result }` or
  `{ "id", "ok": false, "error": { "code", "message" } }`. The `id` is echoed back as given: any JSON value.
- Several clients may connect at once. All requests run one at a time on one queue, so each client gets its
  responses in request order.
- Ops: `ui.observe` and `ui.act` as in the spec, plus `ping`, which returns `{ "trusted": bool, "version" }` so
  `hands` can tell whether a helper is reachable and trusted before it advertises `ui.observe` and `ui.act` in
  `hello.features`.
- The log goes to stderr: one line per request, with the op, the outcome and the time taken. Typed text is never logged.

To poke at it by hand (the AX ops need the grant):

```sh
printf '{"id":1,"op":"ping"}\n' | nc -U ~/Library/Application\ Support/hands/desktop.sock
```

`nc` may exit before the reply arrives. If so, add `sleep 1;` before `printf` and wrap both in a subshell, or use
`socat - UNIX-CONNECT:<path>`.

### Behaviour worth knowing

- **Observations.** Only the latest observation is kept. Its refs (`e1`, `e2`, ...) map to AX elements. A `ui.act`
  naming any other observation id gets `stale`, and so does one sent when the helper has no observation (for example
  after a restart). Observation ids are `o-N`, with N starting at a random number in each process.
- **`observation` in `ui.act`** is required for everything except `OPEN_APP`, `QUIT_APP`, `OPEN_URL` and
  `OPEN_FOLDER`. When those four carry one, it is checked too.
- **Operations per element.** `PRESS`, `SELECT`, `FOCUS` and `TYPE_TEXT` with a `ref` must be listed in the element's
  `operations` (`FOCUS` also accepts elements that list `type`). Otherwise the request is `invalid`. `CLICK` is
  accepted on any ref, as a fallback: it clicks the centre only when that element is what the pointer would land on.
- **Before acting**, the observed app is brought to the front, and the element is checked to still exist, have the
  same label and sit in the same focused window. Otherwise the result is `stale`.
- **Limits.** `maxElements` is 1-1000 (default 150). `text` is at most 10,000 characters. `times` is 1-100 for keys
  and 1-50 for scrolling. A request line is at most 1 MiB.
- **`OPEN_URL`** accepts only http and https. A bare host gets `https://`. The URL opens in the default browser.
- **`OPEN_FOLDER`** accepts `~`, `~/...`, absolute paths, paths relative to home, and the names Home, Desktop,
  Documents, Downloads, Pictures, Music, Movies and Applications. The folder opens in Finder.
- **`QUIT_APP`** uses `NSRunningApplication.terminate()` and is never forced. An app that asks to save stays open,
  and the result says so.
- **Secure input.** Secure text fields are left out of observations. `TYPE_TEXT`, and `PRESS_KEY` with a character,
  are refused while a secure field has focus or secure keyboard entry is on.
- **`PRESS_KEY`** also accepts `enter`, `esc`, `backspace`, `forwarddelete`, `home` and `end`. Uppercase letters and
  shifted symbols add shift. A character with no US-layout key (é) is sent as unicode, without modifiers.
- **`SCROLL`** scrolls about 85% of the visible height per time. The result says whether the content moved, when the
  app reports a scroll bar.
- **`screenChanged`** compares a fingerprint taken just before the action with one taken 250 ms after it. The
  fingerprint covers the app, the focused window's title and frame, the focused control, the number of elements, and
  a digest of up to 400 elements' roles, labels and values. App-level operations fingerprint the frontmost app; the
  others fingerprint the observed app.

## CLI

```
hands-desktop serve [--socket PATH]
hands-desktop observe [--app X] [--max N]
hands-desktop act '<json>' [--app X]
hands-desktop doctor
hands-desktop request-permission
hands-desktop --version
```

`observe` and `act` print one pretty-printed response and exit 1 on an error. Each `act` is a new process, so it takes
a fresh observation first, of `--app` or the frontmost app, and uses that observation's refs. Those match the refs a
preceding `observe` printed only if the screen has not changed. For example:

```sh
hands-desktop observe --app Notes
hands-desktop act '{"operation":"PRESS","ref":"e1"}' --app Notes
hands-desktop act '{"operation":"PRESS_KEY","key":"z","modifiers":["cmd"]}'
```

## LaunchAgent

[`LaunchAgent/dev.mycroft.hands-desktop.plist.template`](LaunchAgent/dev.mycroft.hands-desktop.plist.template) runs
`hands-desktop serve` in the Aqua (GUI) session. It restarts the helper if it exits and logs to
`$HANDS_STATE_DIR/desktop.log`. `hands` is expected to install it:

1. Copy the binary somewhere stable, for example next to `hands`.
2. Fill in `{{HANDS_DESKTOP_BIN}}` and `{{HANDS_STATE_DIR}}`, then write the result to
   `~/Library/LaunchAgents/dev.mycroft.hands-desktop.plist`.
3. `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.mycroft.hands-desktop.plist`. Restart the helper with
   `launchctl kickstart -k gui/$(id -u)/dev.mycroft.hands-desktop`; remove it with `launchctl bootout`.
4. Ask the user to grant Accessibility: `hands-desktop request-permission` from the GUI session, or System Settings.
   Then restart the helper.

`hands` then connects to `desktop.sock`, sends `ping`, and proxies `ui.observe` and `ui.act` lines as they are. It
answers `not_supported` itself when the socket is missing or refuses connections.
