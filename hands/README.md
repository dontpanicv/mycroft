# hands

`hands` is the executing half of Mycroft. It's a small daemon for **macOS and Linux** that you install on your Macs and servers. The brain on the iPhone pairs with it and connects to its TLS listener, and uses it to work with files, run commands and jobs, and on macOS to drive the desktop.

> Status: 0.2 (milestone M5). Files, exec, PTY and `listFiles` work as in pi-env, and supervised jobs are added. The paired TLS listener replaces SSH as the default transport ([ADR 0008](../docs/decisions/0008-hands-transport-pairing.md), [docs/pairing.md](docs/pairing.md)); SSH still works. On macOS, desktop control (`ui.observe`, `ui.act`, `ui.screenshot`) goes through the Mycroft Hands helper app ([../desktop](../desktop/README.md), [docs/desktop-protocol.md](../docs/desktop-protocol.md)). See [ADR 0005](../docs/decisions/0005-hands-daemon.md).

`hands` is built on the pi-env daemon of [Pi](https://github.com/earendil-works/pi) (MIT). See [NOTICE](NOTICE).

## Install

**From the phone.** In Mycroft, tap **Add machine** and pick the network the machine shares with the phone: Wi-Fi, Tailscale, NetBird, or the phone's hotspot. The app copies a command short enough to type:

```sh
curl -fsS 100.92.235.118:8484/k7m2qx | sh
```

Paste or type it into a terminal on the Mac or Linux machine. The phone serves the install script ([scripts/phone-install.sh](scripts/phone-install.sh)), then the binary for this OS and architecture over HTTPS pinned to the phone's key. The script checks the binary's SHA-256. On a network you don't trust, use **Copy pinned command** instead (`curl -fsSLk --pinnedpubkey sha256//PIN https://IP:8485/S | sh`), which pins the script too. The script then runs `hands install --pair`, which:
- installs the binary and the service;
- pairs the machine with the phone;
- prints `Paired with <phone>. Mycroft can use this Mac now.`

On a Mac, when the phone serves `MycroftHands.zip`, the script also downloads and verifies it and passes it to `install --desktop-zip`, which installs the desktop helper and opens it so macOS asks for its permissions. `install` then prints one more line asking you to approve "Mycroft Hands" for Accessibility and Screen Recording.

The command works once and expires after 10 minutes.

**By hand** (development, or servers reached over SSH):

```sh
scripts/build-release.sh            # builds dist/hands-<os>-<arch> for all four targets, and SHA256SUMS
scripts/install.sh --dry-run        # shows what would happen
scripts/install.sh                  # picks the binary for this OS/arch, verifies it, runs `hands install`
hands pair --with BASE --pin PIN    # pair with a phone, given the BASE and PIN of its install command

# macOS desktop control (see ../desktop/README.md):
../desktop/scripts/build.sh                                       # builds ../desktop/dist/MycroftHands.zip
hands install --desktop-zip ../desktop/dist/MycroftHands.zip      # installs the helper, asks for its permissions
hands desktop permissions                                         # what the helper has been granted
```

`hands install` copies the binary to `~/.local/bin/hands` and runs `hands supervise --listen` as a user service. That process is the supervisor of jobs and the phone's listener:

- **Linux:** a systemd user unit, `~/.config/systemd/user/hands.service` (`KillMode=process`, so stopping or upgrading the supervisor leaves jobs running). It also runs `loginctl enable-linger`, so the supervisor keeps running without a login session.
- **macOS:** a LaunchAgent, `~/Library/LaunchAgents/dev.mycroft.hands.plist` (label `dev.mycroft.hands`), loaded with `launchctl bootstrap gui/<uid>`. On a Mac with no GUI login (SSH only), loading fails and the agent loads at the next login.

Running `hands install` again converges to the same state:
- `--dry-run` prints every step, including the files it would write.
- `--uninstall` reverses the install and keeps the state dir.
- `--no-service` skips the service.
- `--bind ADDR` makes the listener listen on one address only, such as a Tailscale address.
- `--desktop-zip PATH` (macOS) also installs the desktop helper from `MycroftHands.zip`; a `MycroftHands.zip` next to the `hands` binary is used without the flag. See [Desktop control](#desktop-control-macos).

With `--pair`, if the service cannot start (or with `--no-service`), the listener runs detached until the machine restarts. `hands serve` still starts a supervisor on demand when none is running.

## Commands

```sh
hands install [--pair BASE --pin PIN] [--desktop-zip PATH] [--no-service] [--bind ADDR] [--dry-run] [--uninstall]
hands pair --with BASE --pin PIN [--bind ADDR]   # pair with a phone; starts the listener if none runs
hands paired [--json]                 # list the paired phones
hands unpair <name>                   # remove a paired phone (by name or public key)
hands supervise [--listen] [--bind ADDR] [--detached]
                                      # the supervisor that owns jobs; with --listen, also the phone's listener
hands serve --stdio [--token <hex>]   # pi-env protocol 1 on stdin/stdout: over ssh, and per listener connection
hands jobs [--json]                   # list supervised jobs (from disk if no supervisor is running)
hands desktop permissions [--request] [--wait N] [--json]
                                      # macOS: Accessibility and Screen Recording of the desktop helper; --request asks
hands doctor                          # binary, version, OS/arch, state dir, supervisor, listener, paired phones, jobs,
                                      # service, and on macOS the desktop helper and its permissions
hands version
```

**The listener** ([docs/pairing.md](docs/pairing.md)) serves WebSocket over TLS 1.3, on a port chosen once, with a self-signed ECDSA P-256 certificate whose SHA-256 the phone pins.
- **Authentication.** The phone authenticates by signing a fresh nonce with its paired Ed25519 key. Nothing else is accepted before that, and the handshake must finish within 10 s.
- **Frames.** After that, each binary message is one pi-env frame. The listener passes the frames to and from a `hands serve` child of its own, so the operations are the same as over SSH.
- **Discovery.** The listener advertises itself over Bonjour as `_mycroft-hands._tcp`.

**pi-env compatibility.** `hands serve --token <hex>` is exactly the command pi-env's `Connection` runs, so `RemoteExecutionEnv` can use `hands` as its daemon. `--stdio` is accepted and implied. Without `--token`, the sync line is `PI-ENV hands`. Run with no arguments and a non-terminal stdin, `hands` also serves.

## Protocol additions

The wire protocol is pi-env's protocol 1, unchanged: [docs/protocol.md](docs/protocol.md) and [docs/semantics.md](docs/semantics.md). `hands` adds operations and lists them in `hello.features`. `hello.version` is the `hands` version.

| op | does |
|---|---|
| `job.start { key, command \| argv, cwd?, env?, inheritEnv?, shellPath? }` | Starts a supervised job. Idempotent by `key`: the same key returns the existing job (`created: false`) and never starts a second process. |
| `job.status { key }` | Returns `state` (`running`/`exited`/`failed`/`cancelled`), `pid`, `exitCode`, `startedAt`, `endedAt`, `outputBytes`. |
| `job.output { key, offset?, maxBytes? }` | Returns raw bytes of the combined stdout+stderr log as payload, with `nextOffset` and `eof`. |
| `job.wait { key, timeoutMs? }` | Waits until the job ends or the timeout passes, without killing it. Returns `timedOut`. |
| `job.cancel { key, signal? }` | Signals the job's whole process group (default `SIGTERM`). |
| `job.list {}` | Lists all jobs, newest first. |
| `ui.observe`, `ui.act`, `ui.screenshot` | macOS desktop control, forwarded to the desktop helper ([docs/desktop-protocol.md](../docs/desktop-protocol.md)). Listed only while the helper answers; otherwise, and on Linux, they fail with `not_supported`. `ui.screenshot` returns the PNG as the payload, with `{ width, height }`. |

[docs/jobs.md](docs/jobs.md) specifies the fields, results and error codes (`EINVAL`, `not_found`, `spawn_error`, `aborted`, `supervisor_unavailable`, ...).

**How jobs outlive the connection.** pi-env kills its commands when the connection drops (stdin ends, or 30 s without bytes). It has to: the brain is a phone that sleeps. Jobs belong to the supervisor instead, so `exec` keeps pi-env's behaviour and `job.*` don't die with the connection. The supervisor runs each job through a tiny runner that leads the job's process group and records the exit code in the job's directory. A job survives `serve` exiting and the supervisor restarting, and its output and exit code can be read after the job ends. Finished jobs are kept for 7 days or until there are 200 of them.

## Desktop control (macOS)

A process started over SSH or by the listener can't hold Accessibility or Screen Recording, so `hands` doesn't touch the desktop itself. It forwards `ui.*` requests to **Mycroft Hands.app** (bundle id `dev.mycroft.hands-desktop`, built from [../desktop](../desktop/README.md)), which runs in your GUI session and holds both permissions.

`hands install --desktop-zip MycroftHands.zip` (or the phone's install):
1. unpacks the app to `~/Applications/Mycroft Hands.app`, after checking its bundle id and signature. An installed copy is replaced only when the version differs.
2. writes the LaunchAgent `~/Library/LaunchAgents/dev.mycroft.hands-desktop.plist`, which runs the app's `hands-desktop serve` with `HANDS_STATE_DIR`, and loads it with `launchctl bootstrap gui/<uid>`.
3. unless both permissions are granted already, opens the app with `open -n -g … --args --request-permissions`, without waiting, and prints one line asking you to approve "Mycroft Hands". macOS shows its prompts for the app (not for your terminal), and System Settings opens at the right pane. The app waits up to 10 minutes for both grants, then restarts the helper.

`--uninstall` removes the app and its LaunchAgent. The grants stay in System Settings; `tccutil reset All dev.mycroft.hands-desktop` removes them. A failure while installing the helper is a warning: `hands` itself is installed and pairs anyway.

`hands desktop permissions` asks the running helper what it has been granted. `--request` opens the app to ask, and waits (default 300 s, `--wait N`) until both are granted.

`hello.features` lists `ui.observe`, `ui.act` and `ui.screenshot` while the helper answers its `ping` (cached for 3 s). Each request opens its own connection to `desktop.sock`; the helper's error codes (`not_trusted`, `not_permitted`, `stale`, ...) come back as the error frame's `code`.

## Where things live

| | macOS | Linux |
|---|---|---|
| binary | `~/.local/bin/hands` | `~/.local/bin/hands` |
| state dir | `~/Library/Application Support/hands` | `$XDG_STATE_HOME/hands` or `~/.local/state/hands` |
| service | `~/Library/LaunchAgents/dev.mycroft.hands.plist` | `~/.config/systemd/user/hands.service` |
| desktop helper | `~/Applications/Mycroft Hands.app`, `~/Library/LaunchAgents/dev.mycroft.hands-desktop.plist` | (none) |

The state dir holds:
- the supervisor's `supervisor.sock`, `supervisor.lock` and `supervisor.log` (the listener logs there too);
- one `jobs/<key>-<hash>/` directory per job (`job.json`, `output.log`);
- the listener's `listener.json` (its port), `listener.lock` and `listener-cert.pem` / `listener-key.pem`;
- `paired.json`, the paired phones' public keys;
- on macOS, the desktop helper's `desktop.sock` and `desktop.log`.

The key, the certificate, `listener.json` and `paired.json` are mode 0600. `HANDS_STATE_DIR` overrides the state dir's location, and `hands install` passes the override on to the service.

## Security

- **One listening port, closed to anyone unpaired.** The listener accepts TLS 1.3 only. Until a peer proves it holds a paired phone's Ed25519 key, it accepts nothing but the `auth` message. The signature covers the listener's certificate hash and a fresh nonce, so it can't be replayed or relayed through another certificate. `--bind` limits the listener to one interface, such as the Tailscale one.
- **Pairing trusts the channel and the code.** The short install command fetches the script over plain HTTP, so it trusts the network path: WireGuard on Tailscale and NetBird, the Wi-Fi otherwise. Everything after that is pinned to the phone's public key (curl `--pinnedpubkey`, and `hands` with rustls), and the pinned command pins the script as well. `hands` sends nothing to a certificate that doesn't match the pin. The one-time setup code expires after 10 minutes, and the phone stops serving after 100 wrong codes. The phone pins the listener's `certSha256` from then on.
- **Same user.** The supervisor's Unix socket is user-only, in the user-only state dir. Over SSH (`hands serve --stdio`), the phone pins the host key as before.
- **No credentials.** No model credentials or API keys ever reach `hands`. Jev and the LLMs are called from the phone.
- **What is stored.** Jobs inherit `serve`'s environment, which may contain secrets, but the environment is never written to disk. `job.json` records only the command or argv, `cwd`, state and timing. Job output is stored as is in the user-only state dir, so a command that prints a secret leaves it in `output.log` until retention deletes it.
- **Same user.** Everything runs as the user who installed `hands`, and `hands` grants nothing beyond what that user's shell can do. Treat a paired phone, or its SSH key, as shell access to the host. `hands unpair` revokes a phone for new connections.
- **Process groups.** Each job is its own session and process group. `job.cancel` signals only that group. The supervisor sends signals only while the job's runner, the group leader, is still alive, so a reused pid is never targeted.
- **Desktop control.** On macOS, Accessibility and Screen Recording are granted to Mycroft Hands.app only, never to `hands` or your terminal. `hands` talks to it over the user-only `desktop.sock`. The helper never runs commands and never reads or types secure text, and it takes a screenshot only for an explicit `ui.screenshot`.

## Development

```sh
cargo build --release
cargo test        # unit tests from pi-env, plus integration tests in tests/ against target/debug/hands
```

The integration tests start `hands serve` and `hands supervise --listen` with a temporary `HANDS_STATE_DIR` under `/tmp`, bind the listener to 127.0.0.1, and never touch the real state dir or install anything. Each test stops its own supervisor when it finishes.

`tests/desktop.rs` runs `ui.*` through `hands serve` against a fake helper on a temporary `desktop.sock`: pass-through of observe, act and screenshot (payload), error codes, `hello.features` only while `ping` answers, `not_supported` without a helper, one connection per concurrent request, `hands desktop permissions`, and the install dry run with a stub zip. Nothing touches the real desktop.

`tests/pairing.rs` runs the whole flow against a fake phone (an HTTPS server with a self-signed certificate):
- `hands pair` pairs the machine and writes `paired.json`;
- a WebSocket client with the phone's key authenticates, and pi-env `hello`, files and `job.*` work through the listener;
- wrong signatures, unknown keys, other messages before `auth`, other paths and a wrong pin are all refused;
- the install script, served and piped to `sh`, `dash`, `zsh` and `bash`, downloads, verifies and runs a stub binary, and refuses a tampered one. On macOS it also fetches a stub `MycroftHands.zip` and passes it on; it refuses a tampered zip, and installs without the helper when the phone does not serve one.

Release builds use `opt-level = "z"`, LTO and one codegen unit, and are stripped. `scripts/build-release.sh` builds the two macOS binaries with cargo and the two static musl Linux binaries with `cargo zigbuild`.

Layout:
- `src/serve.rs` is pi-env's daemon loop (formerly its `main.rs`), with the `job.*` and `ui.*` dispatch added.
- `src/supervisor.rs` contains the supervisor and its client.
- `src/jobs.rs` contains the job table, persistence, runner and retention.
- `src/listener.rs` contains the TLS WebSocket listener, its handshake and the frame proxy.
- `src/pairing.rs` contains `hands pair`, the pairing client and `paired.json`.
- `src/tls.rs` contains the certificate, the SPKI pin and the encodings.
- `src/mdns.rs` contains Bonjour.
- `src/state.rs` contains the paths.
- `src/install.rs` contains `hands install`.
- `src/cli.rs` contains `hands jobs`, `paired`, `unpair` and `doctor`.
- `src/ui/mod.rs` forwards `ui.*` to the desktop helper; `src/ui/app.rs` installs the helper and asks for its permissions (`hands desktop`).

The other files come from pi-env.

## Planned

- Auto-update by SHA-256, as pi-env deploys its daemon.
