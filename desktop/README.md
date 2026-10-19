# Mycroft Hands (hands-desktop)

The macOS desktop-control helper of Mycroft's [`hands`](../hands/README.md) daemon, shipped as **Mycroft Hands.app**
(bundle id `dev.mycroft.hands-desktop`, no Dock icon). It runs in the logged-in user's GUI session with Accessibility
and Screen Recording permission, reads the Accessibility (AX) tree of the app in front, performs UI actions, and
captures the screen on request. `hands` cannot do this itself: a process started over SSH never gets these
permissions. So `hands` proxies `ui.observe`, `ui.act` and `ui.screenshot` to this helper over a Unix socket.

The contract is [docs/desktop-protocol.md](../docs/desktop-protocol.md); the loop around it is
[ADR 0006](../docs/decisions/0006-computer-use-with-jev.md). The reading and acting code is ported from
[jev-use](https://github.com/savka777/jev-use) (MIT); see [NOTICE](NOTICE).

No shell commands are run, no secure text is read or typed, and a screenshot is taken only for an explicit
`ui.screenshot`.

## Build and test

```sh
swift build                 # debug build: .build/debug/hands-desktop
swift test                  # no permissions needed; a fake backend stands in for AX and ScreenCaptureKit
./scripts/build.sh          # dist/Mycroft Hands.app (universal, signed) and dist/MycroftHands.zip
```

Swift 6, macOS 14 or later. `DesktopCore` holds everything (the JSON contract, request dispatch, the socket server,
the permission flow, and the AX and ScreenCaptureKit backend behind the `DesktopBackend` protocol); the
`hands-desktop` executable is a thin CLI over it. The tests never perform real UI actions, take screenshots or prompt
for permissions. One read-only test observes the frontmost app, and it runs only when the test process is already
trusted for Accessibility.

`scripts/build.sh` assembles `dist/Mycroft Hands.app`:
- `Contents/MacOS/hands-desktop`, arm64 + x86_64;
- `Contents/Info.plist`, copied from `Sources/hands-desktop/Info.plist` (`LSUIElement`, usage strings, and the
  version, which must match `handsDesktopVersion`);
- signed, then zipped to `dist/MycroftHands.zip` with `ditto -c -k --keepParent` (without extended attributes).

That zip is what `hands install --desktop-zip` and the phone's install take. The script picks the signing identity:
- `CODESIGN_IDENTITY` set: that identity (a name or SHA-1 hash), with the hardened runtime and a secure timestamp.
  `CODESIGN_IDENTITY=-` forces ad hoc.
- Otherwise: the first "Apple Development" identity in the keychain whose certificate isn't revoked, by SHA-1 hash
  (two certificates often share a name), with the hardened runtime.
- Otherwise: ad hoc.

TCC keys both grants to the bundle id and the signing team, so they survive rebuilds signed by the same team. An
ad-hoc build is keyed to that exact build and needs both grants again after every rebuild.

## Permissions

The helper needs **Accessibility** for `ui.observe` and `ui.act`, and **Screen Recording** for `ui.screenshot`. Only
the user can grant them. The helper never changes privacy settings itself: it only triggers macOS's own prompts and
opens System Settings.

macOS asks for, and grants, both permissions to the *responsible* app of a process. Started by launchd (the
LaunchAgent, or `open`), that is Mycroft Hands. Started from a terminal, it is the terminal app. So:

```sh
open -n "Mycroft Hands.app" --args --request-permissions   # the request flow, inside the app: prompts name Mycroft Hands
hands desktop permissions --request                        # the same through hands, which then waits for both grants
hands-desktop permissions [--json]                         # from a shell: asks the running helper
```

The request flow is `--request-permissions [--only accessibility|screen-recording] [--wait SECONDS]`, with a default
wait of 300 s. Opening the app with no arguments, as Finder does, runs it too. It asks for one permission at a time,
because macOS shows one permission prompt at a time (asking for both at once lost the second):
1. reads both permissions, and stops there if those it was asked for are granted;
2. if Accessibility is missing, calls `AXIsProcessTrustedWithOptions` with the prompt option, opens
   `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`, and waits until it is granted;
3. only then, if Screen Recording is missing, calls `CGRequestScreenCaptureAccess`, opens `…?Privacy_ScreenCapture`,
   and waits until it is granted. `--only` asks for just the one named, which is what `hands permissions` does, step
   by step;
4. polls once a second while it waits, and gives up when the wait runs out. Each poll runs
   `hands-desktop permissions --json --in-process` as a child, because a process sees a Screen Recording grant only
   after a restart;
5. restarts the serving helper (`launchctl kickstart -k gui/<uid>/dev.mycroft.hands-desktop`) if anything changed.

Started from a terminal, `hands-desktop permissions --request` opens the app with `open -n` to run that flow, then
follows the serving helper's `ping`.

Without the grants the helper still serves: `ping` answers, `ui.observe` and `ui.act` return `not_trusted`, and
`ui.screenshot` returns `not_permitted`, each with instructions.

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
- Ops: `ui.observe`, `ui.act` and `ui.screenshot` as in the spec, plus `ping`. `ping` returns
  `{ "trusted": bool, "screenRecording": bool, "version" }`, so `hands` can tell whether a helper is reachable before
  it advertises the `ui.*` ops in `hello.features`.
- `ui.screenshot` answers `{ "png": "<base64>", "width", "height" }`. `hands` turns `png` into the frame's payload.
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
- **`ui.screenshot`** captures the main display with ScreenCaptureKit, the pointer included, at its native pixel
  size scaled down to `maxWidth` (1-8192, default 1600). It needs Screen Recording, not Accessibility, and leaves the
  current observation alone. A capture macOS refuses is `not_permitted`; one that takes over 10 s is `failed`.
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
hands-desktop screenshot --out FILE [--max-width N]
hands-desktop permissions [--json] [--request] [--only accessibility|screen-recording] [--wait SECONDS]
hands-desktop --request-permissions [--only accessibility|screen-recording] [--wait SECONDS]
                                                         # request-permission: the 0.1 name of permissions --request
hands-desktop doctor
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

`screenshot` and `permissions` from a terminal answer for the terminal app, except that `permissions` asks the running
helper when one answers.

## LaunchAgent

`hands install --desktop-zip MycroftHands.zip` installs the helper (see [hands/README.md](../hands/README.md)):

1. It unpacks the app to `~/Applications/Mycroft Hands.app`. It checks the bundle id and the signature first, and
   replaces an installed copy only when the version differs.
2. It fills [`LaunchAgent/dev.mycroft.hands-desktop.plist.template`](LaunchAgent/dev.mycroft.hands-desktop.plist.template)
   with the app's binary and the state dir and writes it to `~/Library/LaunchAgents/dev.mycroft.hands-desktop.plist`.
   Then it loads it with `launchctl bootstrap gui/$(id -u) …`. The agent runs `hands-desktop serve` in the Aqua (GUI)
   session with `HANDS_STATE_DIR`, restarts it if it exits, and logs to `$HANDS_STATE_DIR/desktop.log`.
3. It then walks through the permissions in the terminal (`hands permissions`), which opens the app once per
   permission: `open -n … --args --request-permissions --only accessibility`, then `--only screen-recording`.

To restart the helper, run `launchctl kickstart -k gui/$(id -u)/dev.mycroft.hands-desktop`. `hands install --uninstall`
boots it out and removes the agent and the app; `tccutil reset All dev.mycroft.hands-desktop` also removes the grants.

`hands` opens one connection to `desktop.sock` per request. It sends `ping` before it lists the `ui.*` ops in
`hello.features`, and it answers `not_supported` itself when the socket is missing or refuses connections.
