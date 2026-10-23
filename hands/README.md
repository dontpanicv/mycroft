# hands

`hands` is the executing half of Mycroft. It's a small daemon for **macOS and Linux** that you install on your Macs and servers. The brain on the iPhone pairs with it and connects to its TLS listener, and uses it to work with files, run commands and jobs, and on macOS to drive the desktop.

> Status: 0.2 (milestone M5). Files, exec and `listFiles` come from pi-env, and supervised jobs are added. The phone connects only through the paired TLS listener ([ADR 0008](../docs/decisions/0008-hands-transport-pairing.md), [docs/pairing.md](docs/pairing.md)); pi-env compatibility and SSH are gone ([ADR 0019](../docs/decisions/0019-drop-pi-env-compat.md)). On macOS, desktop control (`cua.tools`, `cua.call`) is [Cua Driver](https://github.com/trycua/cua), linked into `hands` and run by its service ([ADR 0018](../docs/decisions/0018-computer-use-with-cua-driver.md)). See [ADR 0005](../docs/decisions/0005-hands-daemon.md).

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

On a Mac, `install` then walks you through the permissions Mycroft needs, one at a time (see [Permissions on macOS](#permissions-on-macos)). Desktop control needs nothing else installed: it is part of `hands`.

The command works once and expires after 10 minutes.

**By hand** (development, or a server without a terminal near the phone):

```sh
scripts/build-release.sh            # builds dist/hands-<os>-<arch> for all four targets, and SHA256SUMS
scripts/install.sh --dry-run        # shows what would happen
scripts/install.sh                  # picks the binary for this OS/arch, verifies it, runs `hands install`
hands pair --with BASE --pin PIN    # pair with a phone, given the BASE and PIN of its install command
hands permissions                   # macOS: asks for what Mycroft needs, desktop control included
```

`hands install` copies the binary to `~/.local/bin/hands` and runs `hands supervise --listen` as a user service. That process is the supervisor of jobs and the phone's listener. The service gets the `PATH` of the shell `install` runs in, since launchd and systemd give services a minimal one: commands and jobs then find `npm`, `brew`, `cargo` or `gh` as your terminal does. Run `hands install` again after changing your `PATH` for good.

- **Linux:** a systemd user unit, `~/.config/systemd/user/hands.service` (`KillMode=process`, so stopping or upgrading the supervisor leaves jobs running). It also runs `loginctl enable-linger`, so the supervisor keeps running without a login session.
- **macOS:** a LaunchAgent, `~/Library/LaunchAgents/dev.mycroft.hands.plist` (label `dev.mycroft.hands`), loaded with `launchctl bootstrap gui/<uid>`. On a Mac with no GUI login (SSH only), loading fails and the agent loads at the next login.

Running `hands install` again converges to the same state:
- `--dry-run` prints every step, including the files it would write.
- `--uninstall` reverses the install and keeps the state dir.
- `--no-service` skips the service.
- `--bind ADDR` makes the listener listen on one address only, such as a Tailscale address.

On macOS, install and `--uninstall` also remove the separate desktop helper an earlier version installed (see [Where things live](#where-things-live)).

With `--pair`, if the service cannot start (or with `--no-service`), the listener runs detached until the machine restarts. A connection still starts a supervisor on demand when none is running; on macOS that one has no desktop control.

## Commands

```sh
hands install [--pair BASE --pin PIN] [--no-service] [--bind ADDR] [--dry-run] [--uninstall]
hands pair --with BASE --pin PIN [--bind ADDR]   # pair with a phone; starts the listener if none runs
hands paired [--json]                 # list the paired phones
hands unpair <name>                   # remove a paired phone (by name or public key)
hands supervise [--listen] [--bind ADDR] [--detached]
                                      # the supervisor that owns jobs; with --listen, also the phone's listener
hands jobs [--json]                   # list supervised jobs (from disk if no supervisor is running)
hands permissions [--check] [--json]  # macOS: walk through what Mycroft needs approved, one at a time; Linux: report
hands doctor                          # binary, version, OS/arch, state dir, supervisor, listener, paired phones, jobs,
                                      # service, and on macOS desktop control (Cua Driver in the supervisor)
hands version
```

**The listener** ([docs/pairing.md](docs/pairing.md)) serves WebSocket over TLS 1.3, on a port chosen once, with a self-signed ECDSA P-256 certificate whose SHA-256 the phone pins.
- **Authentication.** The phone authenticates by signing a fresh nonce with its paired Ed25519 key. Nothing else is accepted before that, and the handshake must finish within 10 s.
- **Frames.** After that, each binary message is one frame of [docs/protocol.md](docs/protocol.md). The listener passes the frames to and from a `hands __serve` child of its own, one per connection, so a crash in one connection's requests ends only that connection.
- **Discovery.** The listener advertises itself over Bonjour as `_mycroft-hands._tcp`.

## Protocol

The wire protocol is pi-env's protocol 1, trimmed to what the Mycroft app sends: `hello`, `write`, `open`, `pread`, `close`, `listFiles` and `exec` ([docs/protocol.md](docs/protocol.md), [docs/semantics.md](docs/semantics.md)). Any other operation fails with `EINVAL`. `hands` adds these and lists them, with `listFiles`, in `hello.features`. `hello.version` is the `hands` version.

| op | does |
|---|---|
| `job.start { key, command \| argv, cwd?, env?, inheritEnv?, shellPath? }` | Starts a supervised job. Idempotent by `key`: the same key returns the existing job (`created: false`) and never starts a second process. |
| `job.status { key }` | Returns `state` (`running`/`exited`/`failed`/`cancelled`), `pid`, `exitCode`, `startedAt`, `endedAt`, `outputBytes`. |
| `job.output { key, offset?, maxBytes? }` | Returns raw bytes of the combined stdout+stderr log as payload, with `nextOffset` and `eof`. |
| `job.wait { key, timeoutMs? }` | Waits until the job ends or the timeout passes, without killing it. Returns `timedOut`. |
| `job.cancel { key, signal? }` | Signals the job's whole process group (default `SIGTERM`). |
| `job.list {}` | Lists all jobs, newest first. |
| `cua.tools {}` | macOS: Cua Driver's MCP tool list and server instructions, as Cua writes them, less the tools `hands` leaves out. |
| `cua.call { name, arguments? }` | macOS: calls one of those tools and returns Cua's MCP result unchanged (`content` with text and base64 images, `structuredContent`, `isError`). On Linux both fail with `not_supported`. |

[docs/jobs.md](docs/jobs.md) specifies the fields, results and error codes (`EINVAL`, `not_found`, `spawn_error`, `aborted`, `supervisor_unavailable`, `not_service`, ...).

**How jobs outlive the connection.** `serve` kills its commands when the connection drops (stdin ends, or 30 s without bytes), as pi-env does. Jobs belong to the supervisor instead, so `exec` keeps that behaviour and `job.*` don't die with the connection: the brain is a phone that sleeps. The supervisor runs each job through a tiny runner that leads the job's process group and records the exit code in the job's directory. A job survives `serve` exiting and the supervisor restarting, and its output and exit code can be read after the job ends. Finished jobs are kept for 7 days or until there are 200 of them.

## Desktop control (macOS)

`hands` links [Cua Driver](https://github.com/trycua/cua) (MIT) as a library: the `cua-driver-sdk` crate and its `cua-driver-core`, `cursor-overlay` and `platform-macos`, pinned to the tag `cua-driver-rs-v0.38.0`. It reads one window at a time (accessibility tree and screenshot, with `element_token`s and diff re-reads), acts in the background without moving your pointer or switching apps, batches steps with checks (`run_steps`), and shows an agent cursor. There is nothing else to install: no Cua app, no `cua-driver` CLI. Linux builds don't have it: they are static musl, and Cua's Linux crates link X11.

- **Where it runs.** In the supervisor that launchd starts, the `dev.mycroft.hands` service. macOS gives Accessibility and Screen Recording to the responsible process; started by launchd, that is `hands` itself. The supervisor creates the driver once at startup, as Cua's own service does (`CuaDriver::try_create_service_for_host`, with `host_owns_permission_ux`: `hands permissions` asks). The agent cursor takes the main thread's AppKit loop, and the supervisor accepts connections on another thread. A supervisor that `serve` started on demand has no desktop, and `cua.*` fail with `not_service`.
- **How calls get there.** `serve` forwards `cua.tools` and `cua.call` over `supervisor.sock`, like `job.*`, with the client (the paired phone's name, or `local`) and a call id. Each client keeps one Cua session across reconnects, so element tokens stay valid. Cancelling a `cua.call` aborts the driver call.
- **What is offered.** Cua's tools as Cua describes them, except `parse_visual_regions` (Cua's perception model isn't linked) and Computer History (`history_*`, off). The phone offers them to its model under their own names, and asks the user before risky actions.
- **Status.** The supervisor's own `hello` has `desktop: { version }` or `desktop: { off: why }`; `hands doctor` shows it.

### Permissions on macOS

`hands permissions` (and `hands install`, right after pairing) walks through everything Mycroft may need on a Mac, one at a time, in the terminal. Each step says what the permission is for, makes macOS ask, and waits with a spinner until it is granted. Enter skips a step; Ctrl-C stops.

```
[1/7] Accessibility: read and use apps' buttons, menus and fields
      When macOS asks, click Open System Settings and turn on "hands" under Accessibility.
      ✓ granted
[2/7] Screen Recording: see the screen when Mycroft takes a screenshot
[3/7] Desktop folder: commands Mycroft runs can read and change files there
[4/7] Documents folder
[5/7] Downloads folder
[6/7] Local Network: commands can reach other devices on your network
[7/7] Full Disk Access (optional): everything else: iCloud Drive, external disks, other apps' data
```

| Permission | Held by | How it is asked |
|---|---|---|
| Accessibility, Screen Recording | hands | the service asks macOS (`AXIsProcessTrustedWithOptions`, `CGRequestScreenCaptureAccess`), which prompts about "hands" and opens System Settings |
| Desktop, Documents, Downloads | hands | the service opens the folder, which makes macOS ask about "hands" |
| Local Network (macOS 15+) | hands | the service sends one UDP packet to the router |
| Full Disk Access (optional) | hands | no prompt exists: System Settings opens and Finder shows `hands`, to drag into the list |

- **Why the service asks.** macOS gives a permission to the responsible process. From Terminal that is Terminal, so the terminal only drives: every item is asked for and checked in the service's supervisor (the `access` op, `access { what, ask: true }` to make macOS ask), which launchd started, so macOS asks about `hands`, and the grant covers desktop control and every command Mycroft runs. A supervisor started from a terminal refuses the op.
- **Screen Recording needs a restart.** macOS tells a process about a new Screen Recording grant only after it restarts. So the supervisor checks Accessibility and Screen Recording in a fresh child (`hands permissions --probe <item>`, which macOS also counts as `hands`), which also says whether it sees the grant itself (`applied`). When it doesn't, whether the grant is new or older than the running service, the walkthrough restarts the service (the supervisor's `shutdown`; launchd starts it again) and waits for it. Running jobs are not affected.
- **A prompt that doesn't come.** macOS asks once. If it was answered before, the walkthrough opens the right System Settings pane after a few seconds and says what to turn on.
- **Kept across updates.** The macOS binaries are signed as `dev.mycroft.hands` (scripts/build-release.sh). Signed with an Apple Development identity, they keep these grants when hands is updated; signed ad hoc (no identity on the build machine), Accessibility and Screen Recording are asked for again after each update.
- **`--check` and `--json`** only report, and never make macOS ask: the folders and Local Network are checked only once a walkthrough has asked about them (`permissions.json` in the state dir). Without a terminal (`ssh` without `-t`, say), `install` prints how to run the walkthrough instead.
- **Linux** has nothing to approve: hands runs as you. `hands permissions` reports what keeps it running instead, the service and lingering (`sudo loginctl enable-linger $USER` keeps it running after logout).

## Where things live

| | macOS | Linux |
|---|---|---|
| binary | `~/.local/bin/hands` | `~/.local/bin/hands` |
| state dir | `~/Library/Application Support/hands` | `$XDG_STATE_HOME/hands` or `~/.local/state/hands` |
| service | `~/Library/LaunchAgents/dev.mycroft.hands.plist` | `~/.config/systemd/user/hands.service` |

The state dir holds:
- the supervisor's `supervisor.sock`, `supervisor.lock` and `supervisor.log` (the listener logs there too);
- one `jobs/<key>-<hash>/` directory per job (`job.json`, `output.log`);
- the listener's `listener.json` (its port), `listener.lock` and `listener-cert.pem` / `listener-key.pem`;
- `paired.json`, the paired phones' public keys;
- on macOS, `permissions.json`, which permissions a walkthrough has asked about.

Earlier versions installed a separate desktop helper on macOS. `hands install` and `--uninstall` remove it if it is there: `~/Applications/Mycroft Hands.app`, `~/Library/LaunchAgents/dev.mycroft.hands-desktop.plist`, and its job (`launchctl bootout gui/<uid>/dev.mycroft.hands-desktop`).

The key, the certificate, `listener.json` and `paired.json` are mode 0600. `HANDS_STATE_DIR` overrides the state dir's location, and `hands install` passes the override on to the service.

## Security

- **One listening port, closed to anyone unpaired.** The listener accepts TLS 1.3 only. Until a peer proves it holds a paired phone's Ed25519 key, it accepts nothing but the `auth` message. The signature covers the listener's certificate hash and a fresh nonce, so it can't be replayed or relayed through another certificate. `--bind` limits the listener to one interface, such as the Tailscale one.
- **Pairing trusts the channel and the code.** The short install command fetches the script over plain HTTP, so it trusts the network path: WireGuard on Tailscale and NetBird, the Wi-Fi otherwise. Everything after that is pinned to the phone's public key (curl `--pinnedpubkey`, and `hands` with rustls), and the pinned command pins the script as well. `hands` sends nothing to a certificate that doesn't match the pin. The one-time setup code expires after 10 minutes, and the phone stops serving after 100 wrong codes. The phone pins the listener's `certSha256` from then on.
- **Same user.** The supervisor's Unix socket is user-only, in the user-only state dir.
- **No credentials, no models.** No model credentials or API keys ever reach `hands`, and it runs no model: the LLMs are called from the phone, and Cua's perception model is not linked.
- **What is stored.** Jobs inherit `serve`'s environment (the service's, with the `PATH` captured at install), which may contain secrets, but the environment is never written to disk. `job.json` records only the command or argv, `cwd`, state and timing. Job output is stored as is in the user-only state dir, so a command that prints a secret leaves it in `output.log` until retention deletes it.
- **Same user.** Everything runs as the user who installed `hands`, and `hands` grants nothing beyond what that user's shell can do. Treat a paired phone as shell access to the host. `hands unpair` revokes a phone for new connections.
- **Process groups.** Each job is its own session and process group. `job.cancel` signals only that group. The supervisor sends signals only while the job's runner, the group leader, is still alive, so a reused pid is never targeted.
- **Desktop control.** On macOS, Accessibility and Screen Recording are granted to `hands` (the service), never to your terminal. A paired phone can then read and use any app's windows, and take screenshots, as well as run commands. Cua Driver runs only in that service, and each client gets its own Cua session. The phone asks the user before actions that look destructive (deleting, sending, paying, quitting, ...); that check is the phone's, not `hands`'.

## Development

```sh
cargo build --release
cargo test        # unit tests from pi-env, plus integration tests in tests/ against target/debug/hands
```

On macOS the first build clones Cua's git repository (about 630 MB), which Cargo keeps for later builds.

The integration tests start `hands __serve` and `hands supervise --listen` with a temporary `HANDS_STATE_DIR` under `/tmp`, bind the listener to 127.0.0.1, and never touch the real state dir or install anything. Each test stops its own supervisor when it finishes.

`tests/desktop.rs` runs `cua.tools` and `cua.call` through `hands __serve` against a fake supervisor on a temporary `supervisor.sock`: both are forwarded and answered unchanged, each call carries `client` and `call`, a cancelled call sends `cua.cancel` and ends with `aborted`, malformed calls stop in `serve`, and a real supervisor that launchd did not start has no desktop. Nothing touches the real desktop or Cua Driver.

`tests/pairing.rs` runs the whole flow against a fake phone (an HTTPS server with a self-signed certificate):
- `hands pair` pairs the machine and writes `paired.json`;
- a WebSocket client with the phone's key authenticates, and `hello`, files and `job.*` work through the listener;
- wrong signatures, unknown keys, other messages before `auth`, other paths and a wrong pin are all refused;
- the install script, served and piped to `sh`, `dash`, `zsh` and `bash`, downloads, verifies and runs a stub binary, and refuses a tampered one.

Release builds use `opt-level = "z"`, LTO and one codegen unit, and are stripped. `scripts/build-release.sh` builds the two macOS binaries with cargo and the two static musl Linux binaries with `cargo zigbuild`.

Layout:
- `src/serve.rs` is pi-env's daemon loop (formerly its `main.rs`): one `Op` per operation the phone sends, with its lane (worker pool or own thread), and the `job.*` and `cua.*` forwarding.
- `src/supervisor.rs` contains the supervisor, its own operations (`hello`, `access`, `shutdown`, and the forwarded `job.*` and `cua.*`) and its client.
- `src/jobs.rs` contains the job table, persistence, runner and retention.
- `src/listener.rs` contains the TLS WebSocket listener, its handshake and the frame proxy.
- `src/pairing.rs` contains `hands pair`, the pairing client and `paired.json`.
- `src/tls.rs` contains the certificate, the SPKI pin and the encodings.
- `src/mdns.rs` contains Bonjour.
- `src/state.rs` contains the paths.
- `src/install.rs` contains `hands install`.
- `src/cli.rs` contains `hands jobs`, `paired`, `unpair` and `doctor`.
- `src/cua.rs` is desktop control: `serve`'s forwarding of `cua.*`, and Cua Driver in the supervisor (sessions, cancellation, the agent cursor's main loop).
- `src/permissions/` is `hands permissions`: the items and the service's `access` op (`mod.rs`), the macOS walkthrough on the terminal (`walkthrough.rs`), and the Linux report (`linux.rs`).

The other files come from pi-env.

## Planned

- Auto-update by SHA-256, as pi-env deploys its daemon.
