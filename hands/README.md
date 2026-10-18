# hands

`hands` is the executing half of Mycroft. It's a small daemon for **macOS and Linux** that you install on your Macs and servers. The brain on the iPhone connects to it over SSH and uses it to work with files, run commands and jobs, and later (on macOS) to drive the desktop.

> Status: v1 (milestone M5). Files, exec, PTY and `listFiles` work as in pi-env, and supervised jobs are added. Desktop control (`ui.*`) is reserved for M6. See [ADR 0005](../docs/decisions/0005-hands-daemon.md).

`hands` is built on the pi-env daemon of [Pi](https://github.com/earendil-works/pi) (MIT). See [NOTICE](NOTICE).

## Install

```sh
scripts/build-release.sh            # builds dist/hands-<os>-<arch> and SHA256SUMS for what this machine can build
scripts/install.sh --dry-run        # shows what would happen
scripts/install.sh                  # picks the binary for this OS/arch, verifies it, runs `hands install`
```

`hands install` copies the binary to `~/.local/bin/hands` and runs `hands supervise` as a user service:

- **Linux:** a systemd user unit, `~/.config/systemd/user/hands.service` (`KillMode=process`, so stopping or upgrading the supervisor leaves jobs running). It also runs `loginctl enable-linger`, so the supervisor keeps running without a login session.
- **macOS:** a LaunchAgent, `~/Library/LaunchAgents/dev.mycroft.hands.plist` (label `dev.mycroft.hands`), loaded with `launchctl bootstrap gui/<uid>`. On a Mac with no GUI login (SSH only), loading fails and the agent loads at the next login. Until then, `hands serve` starts the supervisor on demand.

Running `hands install` again converges to the same state. `--dry-run` prints every step, including the files it would write. `--uninstall` reverses the install and keeps the state dir. The service is optional, because `hands serve` starts a supervisor itself when none is running.

## Commands

```sh
hands serve --stdio [--token <hex>]   # what the phone runs over ssh: pi-env protocol 1 on stdin/stdout
hands supervise                       # the long-lived supervisor that owns jobs (run by the service)
hands install [--dry-run] [--uninstall]
hands jobs [--json]                   # list supervised jobs (from disk if no supervisor is running)
hands doctor                          # binary, version, OS/arch, state dir, supervisor, jobs, service
hands version
```

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

The state dir holds `supervisor.sock`, `supervisor.lock`, `supervisor.log` and `jobs/<key>-<hash>/` (`job.json`, `output.log`). `HANDS_STATE_DIR` overrides its location. `hands install` passes the override on to the service.

## Security

- **SSH only, and no listening ports.** The phone runs `hands serve` through `ssh` and pins the host key from pairing. The supervisor listens only on a Unix socket inside the state dir. The state dir is mode 0700 and the socket is created user-only, so only the same user can reach it.
- **No credentials.** No model credentials or API keys ever reach `hands`. Jev and the LLMs are called from the phone.
- **What is stored.** Jobs inherit `serve`'s environment, which may contain secrets, but the environment is never written to disk. `job.json` records only the command or argv, `cwd`, state and timing. Job output is stored as is in the user-only state dir, so a command that prints a secret leaves it in `output.log` until retention deletes it.
- **Same user.** Everything runs as the SSH user, and `hands` grants nothing beyond what that user's shell can do. Treat access to the phone's SSH key as shell access to the host.
- **Process groups.** Each job is its own session and process group. `job.cancel` signals only that group. The supervisor sends signals only while the job's runner, the group leader, is still alive, so a reused pid is never targeted.
- **Desktop control (M6).** On macOS, Accessibility permission will be granted to a separate LaunchAgent in the GUI session only. The SSH-side process will talk to it over another user-only Unix socket (see `src/ui/mod.rs`).

## Development

```sh
cargo build --release
cargo test        # unit tests from pi-env, plus integration tests in tests/ against target/debug/hands
```

The integration tests start `hands serve` with a temporary `HANDS_STATE_DIR` under `/tmp` and never touch the real state dir or install anything. Each test stops its own supervisor when it finishes.

Layout: `src/serve.rs` is pi-env's daemon loop (formerly its `main.rs`) with the `job.*` and `ui.*` dispatch added. `src/supervisor.rs` contains the supervisor and its client. `src/jobs.rs` contains the job table, persistence, runner and retention. `src/state.rs` contains the paths, `src/install.rs` contains `hands install`, `src/cli.rs` contains `hands jobs` and `hands doctor`, and `src/ui/` holds the M6 stub. The other files come from pi-env.

## Planned

- `hands pair`: print a QR code or pairing string with this host's key and address.
- Desktop control on macOS: `ui.observe` returns the AX tree with element refs, and `ui.act` presses, types, scrolls and focuses. Both go through a LaunchAgent that holds the Accessibility permission.
- Auto-update by SHA-256, as pi-env deploys its daemon.
