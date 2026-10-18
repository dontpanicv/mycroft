# hands

`hands` is the executing half of Mycroft. It's a small daemon for **macOS and Linux** that you install on your Macs and servers. The brain on the iPhone pairs with it and connects to its TLS listener, and uses it to work with files, run commands and jobs, and later (on macOS) to drive the desktop.

> Status: 0.2 (milestone M5). Files, exec, PTY and `listFiles` work as in pi-env, and supervised jobs are added. The paired TLS listener replaces SSH as the default transport ([ADR 0008](../docs/decisions/0008-hands-transport-pairing.md), [docs/pairing.md](docs/pairing.md)); SSH still works. Desktop control (`ui.*`) is reserved for M6. See [ADR 0005](../docs/decisions/0005-hands-daemon.md).

`hands` is built on the pi-env daemon of [Pi](https://github.com/earendil-works/pi) (MIT). See [NOTICE](NOTICE).

## Install

**From the phone.** In Mycroft, tap **Add machine**. The app copies a command like this:

```sh
curl -fsSLk --pinnedpubkey sha256//PIN https://IP:P/S | sh
```

Paste it into a terminal on the Mac or Linux machine, on the same network as the phone. The phone serves the install script ([scripts/phone-install.sh](scripts/phone-install.sh)) and the binary for this OS and architecture. curl accepts only the phone's pinned key, and the script checks the binary's SHA-256. The script then runs `hands install --pair`, which:
- installs the binary and the service;
- pairs the machine with the phone;
- prints `Paired with <phone>. Mycroft can use this Mac now.`

The command works once and expires after 10 minutes.

**By hand** (development, or servers reached over SSH):

```sh
scripts/build-release.sh            # builds dist/hands-<os>-<arch> for all four targets, and SHA256SUMS
scripts/install.sh --dry-run        # shows what would happen
scripts/install.sh                  # picks the binary for this OS/arch, verifies it, runs `hands install`
hands pair --with BASE --pin PIN    # pair with a phone, given the BASE and PIN of its install command
```

`hands install` copies the binary to `~/.local/bin/hands` and runs `hands supervise --listen` as a user service. That process is the supervisor of jobs and the phone's listener:

- **Linux:** a systemd user unit, `~/.config/systemd/user/hands.service` (`KillMode=process`, so stopping or upgrading the supervisor leaves jobs running). It also runs `loginctl enable-linger`, so the supervisor keeps running without a login session.
- **macOS:** a LaunchAgent, `~/Library/LaunchAgents/dev.mycroft.hands.plist` (label `dev.mycroft.hands`), loaded with `launchctl bootstrap gui/<uid>`. On a Mac with no GUI login (SSH only), loading fails and the agent loads at the next login.

Running `hands install` again converges to the same state:
- `--dry-run` prints every step, including the files it would write.
- `--uninstall` reverses the install and keeps the state dir.
- `--no-service` skips the service.
- `--bind ADDR` makes the listener listen on one address only, such as a Tailscale address.

With `--pair`, if the service cannot start (or with `--no-service`), the listener runs detached until the machine restarts. `hands serve` still starts a supervisor on demand when none is running.

## Commands

```sh
hands install [--pair BASE --pin PIN] [--no-service] [--bind ADDR] [--dry-run] [--uninstall]
hands pair --with BASE --pin PIN [--bind ADDR]   # pair with a phone; starts the listener if none runs
hands paired [--json]                 # list the paired phones
hands unpair <name>                   # remove a paired phone (by name or public key)
hands supervise [--listen] [--bind ADDR] [--detached]
                                      # the supervisor that owns jobs; with --listen, also the phone's listener
hands serve --stdio [--token <hex>]   # pi-env protocol 1 on stdin/stdout: over ssh, and per listener connection
hands jobs [--json]                   # list supervised jobs (from disk if no supervisor is running)
hands doctor                          # binary, version, OS/arch, state dir, supervisor, listener, paired phones, jobs, service
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
| `ui.observe`, `ui.act` | Reserved. They fail with `not_supported`. |

[docs/jobs.md](docs/jobs.md) specifies the fields, results and error codes (`EINVAL`, `not_found`, `spawn_error`, `aborted`, `supervisor_unavailable`, ...).

**How jobs outlive the connection.** pi-env kills its commands when the connection drops (stdin ends, or 30 s without bytes). It has to: the brain is a phone that sleeps. Jobs belong to the supervisor instead, so `exec` keeps pi-env's behaviour and `job.*` don't die with the connection. The supervisor runs each job through a tiny runner that leads the job's process group and records the exit code in the job's directory. A job survives `serve` exiting and the supervisor restarting, and its output and exit code can be read after the job ends. Finished jobs are kept for 7 days or until there are 200 of them.

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
- `paired.json`, the paired phones' public keys.

The key, the certificate, `listener.json` and `paired.json` are mode 0600. `HANDS_STATE_DIR` overrides the state dir's location, and `hands install` passes the override on to the service.

## Security

- **One listening port, closed to anyone unpaired.** The listener accepts TLS 1.3 only. Until a peer proves it holds a paired phone's Ed25519 key, it accepts nothing but the `auth` message. The signature covers the listener's certificate hash and a fresh nonce, so it can't be replayed or relayed through another certificate. `--bind` limits the listener to one interface, such as the Tailscale one.
- **Pairing trusts the channel and the code.** The install command pins the phone's public key (curl `--pinnedpubkey`, and `hands` with rustls). `hands` sends nothing to a certificate that doesn't match the pin. The one-time setup id expires after 10 minutes. The phone pins the listener's `certSha256` from then on.
- **Same user.** The supervisor's Unix socket is user-only, in the user-only state dir. Over SSH (`hands serve --stdio`), the phone pins the host key as before.
- **No credentials.** No model credentials or API keys ever reach `hands`. Jev and the LLMs are called from the phone.
- **What is stored.** Jobs inherit `serve`'s environment, which may contain secrets, but the environment is never written to disk. `job.json` records only the command or argv, `cwd`, state and timing. Job output is stored as is in the user-only state dir, so a command that prints a secret leaves it in `output.log` until retention deletes it.
- **Same user.** Everything runs as the user who installed `hands`, and `hands` grants nothing beyond what that user's shell can do. Treat a paired phone, or its SSH key, as shell access to the host. `hands unpair` revokes a phone for new connections.
- **Process groups.** Each job is its own session and process group. `job.cancel` signals only that group. The supervisor sends signals only while the job's runner, the group leader, is still alive, so a reused pid is never targeted.
- **Desktop control (M6).** On macOS, Accessibility permission will be granted to a separate LaunchAgent in the GUI session only. The SSH-side process will talk to it over another user-only Unix socket (see `src/ui/mod.rs`).

## Development

```sh
cargo build --release
cargo test        # unit tests from pi-env, plus integration tests in tests/ against target/debug/hands
```

The integration tests start `hands serve` and `hands supervise --listen` with a temporary `HANDS_STATE_DIR` under `/tmp`, bind the listener to 127.0.0.1, and never touch the real state dir or install anything. Each test stops its own supervisor when it finishes.

`tests/pairing.rs` runs the whole flow against a fake phone (an HTTPS server with a self-signed certificate):
- `hands pair` pairs the machine and writes `paired.json`;
- a WebSocket client with the phone's key authenticates, and pi-env `hello`, files and `job.*` work through the listener;
- wrong signatures, unknown keys, other messages before `auth`, other paths and a wrong pin are all refused;
- the install script, served and piped to `sh`, `dash`, `zsh` and `bash`, downloads, verifies and runs a stub binary, and refuses a tampered one.

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
- `src/ui/` holds the M6 stub.

The other files come from pi-env.

## Planned

- Desktop control on macOS: `ui.observe` returns the AX tree with element refs, and `ui.act` presses, types, scrolls and focuses. Both go through a LaunchAgent that holds the Accessibility permission.
- Auto-update by SHA-256, as pi-env deploys its daemon.
