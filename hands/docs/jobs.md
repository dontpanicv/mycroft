# Supervised jobs

`hands` adds supervised jobs to protocol 1 ([protocol.md](protocol.md)). An `exec` dies with its connection: the
daemon kills every command it started when stdin ends or after 30 seconds of silence. A job does not. It belongs to
the **supervisor** (`hands supervise`), a long-lived process per user, and keeps running while the phone sleeps,
loses its network, or reconnects through a new `hands __serve`.

The operations are listed in `hello.features`. A client checks for them there, as it checks for `listFiles`.

## Model

- A job is named by a **key** chosen by the client: a string of 1 to 1024 bytes. The brain uses the durable
  tool-call id, so a replayed tool call finds the job it started instead of starting another one.
- `job.start` is idempotent by key. If a job with the key exists, running or finished, it is returned with
  `created: false` and nothing is started. The other fields of the repeated request are ignored.
- A job runs a shell string (`command`, through the shell `exec` would use) or an argv array (`argv`). It runs in
  a new session, so all its processes form one process group. stdin is `/dev/null`. stdout and stderr go together,
  in arrival order, to one **output log** that the job writes directly. The log is stored as raw bytes and is not
  decoded.
- The job's environment is the one `exec` would give it: the environment of `hands __serve` (the service's, with
  the `PATH` `hands install` captured from the user's shell), then `env`. With `inheritEnv: false`, only `env` is used. The environment is never written to disk.
- States: `running`, then one of these:
  - `exited`: the command ended by itself. `exitCode` is its code, or 128 + the signal number if a signal killed it.
  - `cancelled`: `job.cancel` signalled it and it then ended. `exitCode` is as for `exited` (e.g. 143 for SIGTERM).
  - `failed`: it could not start (a program that does not exist), or its exit status was lost. See `error`.

## Operations

All requests are request frames (`type 1`) with `json.op` set. Results and errors are result and error frames. Fields in brackets are optional.

### Job status

`job.status`, `job.wait`, `job.cancel`, `job.list` and `job.start` all return this record:

| field | type | meaning |
|---|---|---|
| `key` | string | the job's key |
| `command` / `argv` | string / string[] | what was started (only one of the two is present) |
| `cwd` | string | working directory |
| `state` | string | `running`, `exited`, `failed` or `cancelled` |
| `pid` | number \| null | the job's process group id. Its leader is `hands`' small runner process, which waits for the command. |
| `exitCode` | number \| null | set once the job has ended, if known |
| `startedAt` | number | Unix time in milliseconds |
| `endedAt` | number \| null | Unix time in milliseconds, once ended |
| `outputBytes` | number | current size of the output log |
| `error` | string? | why a job `failed`, e.g. `spawn_error: No such file or directory (os error 2)` |
| `cancelSignal` | number? | the signal `job.cancel` sent |

### `job.start { key, command | argv, [cwd], [env], [inheritEnv], [shellPath] }`

| field | default | meaning |
|---|---|---|
| `key` | required | idempotency key, 1 to 1024 bytes |
| `command` | | shell string, run as `<shell> -c <command>`. The shell is resolved as for `exec`: `shellPath`, then `/bin/bash`, `which bash`, then `sh`. |
| `argv` | | program and arguments. The program is looked up in `PATH` of the job's environment. |
| `cwd` | the user's home | absolute working directory, which must exist |
| `env` | `{}` | variables added on top of the inherited environment |
| `inheritEnv` | `true` | start from `hands __serve`'s environment |
| `shellPath` | | shell for `command`. It must exist. |

→ the status record plus `created: boolean`. A new job is returned as `running`. A program that cannot be executed
(for example, a missing argv program) is still reported as started, and then ends as `failed` with
`error: "spawn_error: ..."`. The same message is written to the output log.

### `job.status { key }`

→ the status record.

### `job.output { key, [offset], [maxBytes] }`

Reads the output log from `offset` (default 0), up to `maxBytes` bytes (default 1 MiB, at most the frame limit
less 64 KiB). The bytes travel as the result's **payload**:

| field | meaning |
|---|---|
| `offset` | the requested offset |
| `nextOffset` | `offset` + the payload length. Pass it as the next `offset`. |
| `outputBytes` | size of the log when it was read |
| `state` | the job's state when it was read |
| `eof` | `true` once the job has ended and everything up to the end of the log has been read |

An offset past the end returns an empty payload. To read the tail, use `offset = outputBytes - n` from a status. To
follow a running job, alternate `job.wait` with a short timeout and `job.output` from `nextOffset` until `eof`.

### `job.wait { key, [timeoutMs] }`

Waits until the job ends or `timeoutMs` (default 30 000) passes. The job keeps running either way. → the status
record plus `timedOut: boolean` (true when it is still running). Cancelling the request with a cancel frame stops
the wait with `aborted` and leaves the job alone. `hands __serve` waits in slices of at most 500 ms, so the
request stops promptly.

### `job.cancel { key, [signal] }`

Sends `signal` to the job's whole process group: the command, its children and anything else they started in the
group. `signal` is a name (`"SIGTERM"` or `"TERM"`; `HUP`, `INT`, `QUIT`, `KILL`, `TERM`, `USR1`, `USR2`) or a
number from 1 to 31. The default is `SIGTERM`.

→ the status record plus `signalled: boolean`. The call does not wait. Follow it with `job.wait`, and send `SIGKILL`
if the job ignores the first signal. Cancelling a job that has already ended does nothing (`signalled: false`). A
job that was signalled ends as `cancelled`.

### `job.list {}`

→ `{ jobs: [status record, ...] }`, newest first. Finished jobs are included until retention removes them.

### Desktop control: `cua.tools`, `cua.call`

macOS only, listed in `features` there. They carry [Cua Driver](https://github.com/trycua/cua)'s MCP tools (MIT),
which `hands` links in: per-window accessibility tree and screenshot reads with `element_token`s, background input
that doesn't move the user's pointer or switch apps, `run_steps` batches, `verify_state`. `hello` also returns
`cua: { version }`, the linked driver's release.

The driver runs in the supervisor that launchd started (the service), because macOS gives Accessibility and Screen
Recording to that process: "hands". `hands __serve` forwards both operations to it over `supervisor.sock`, as it does
`job.*`.

#### `cua.tools {}`

→ `{ version, instructions, tools }`. `tools` are Cua's MCP `tools/list` entries as Cua describes them (`name`,
`description`, `inputSchema`, `annotations`, ...), and `instructions` is the text of Cua's MCP server
`instructions`. Both are unchanged, except that the tools `hands` does not offer are left out, with the instructions'
sentence about them: `parse_visual_regions` (it needs Cua's perception model, which `hands` doesn't link) and the
Computer History tools (`history_*`; History is off).

#### `cua.call { name, [arguments] }`

| field | default | meaning |
|---|---|---|
| `name` | required | a tool from `cua.tools` |
| `arguments` | `{}` | the tool's arguments, an object, as its `inputSchema` describes |

→ Cua's MCP `CallToolResult`, unchanged: `{ content: [...], [structuredContent], [isError] }`. Each `content` item
is `{ type: "text", text }` or `{ type: "image", data, mimeType }` (base64). A tool that runs but fails returns a
normal result with `isError: true`; the error codes below are for calls that don't run.

- **What the supervisor gets.** `serve` checks `name` and `arguments`, and adds `client` and `call`: `client` is the
  paired phone's name (`HANDS_PEER`, which the listener sets) or `local`, and `call` is a random id.
- **Cancellation.** A cancel frame stops the request with `aborted`, and `serve` sends the supervisor
  `cua.cancel { call }`, which aborts the driver call.
- **Sessions.** Each client has one Cua trusted session (standard permission mode). It is kept across reconnects, so
  element tokens from earlier reads stay valid. Cua ends a session after 24 hours, or after an hour without a call;
  `hands` starts a fresh one a minute before either.

The supervisor's own `hello` (its socket's operation for the CLI, not the client's `hello`, which `serve` answers) reports
`desktop: { version }` while the driver runs, or `desktop: { off: why }`.
`hands doctor` shows it in its `desktop` row.

## Errors

Errors have the protocol's shape `{ code, message, ... }`. Only `code` is part of the contract.

| code | when |
|---|---|
| `EINVAL` | missing or invalid field: no or empty `key`, a key over 1024 bytes, neither `command` nor `argv`, `argv` holding non-strings, an unknown `signal` |
| `not_found` | no job with this key (never started, or deleted by retention) |
| `spawn_error` | `cwd` does not exist, `argv` is empty, or the runner could not be started. No job is recorded, so the key stays free. |
| `shell_unavailable` | `shellPath` does not exist |
| `aborted` | a `job.wait` or `cua.call` was cancelled by the client |
| `supervisor_unavailable` | `hands __serve` could not reach or start the supervisor |
| `not_supported` | `cua.*` on Linux |
| `not_service` | `cua.*` when the supervisor wasn't started by launchd (it was started on demand by `serve`): `hands install` sets the service up |
| `unavailable` | Cua Driver could not start in the supervisor |
| `EINVAL` | also: `cua.call` without `name`, with `arguments` that aren't an object, with an unknown tool or one `hands` leaves out, or with arguments Cua finds invalid |
| `interrupted` | Cua interrupted the action (its `ActionInterrupted`) |
| Cua's code | Cua refused the tool call; the code is Cua's own |
| `failed` | any other driver error |

## The supervisor

- `hands __serve` reaches the supervisor over the Unix socket `supervisor.sock` in the **state dir**. The state dir
  is `~/Library/Application Support/hands` on macOS, and `$XDG_STATE_HOME/hands` or `~/.local/state/hands` on
  Linux. `HANDS_STATE_DIR` overrides it, and the tests use that. The state dir is mode 0700, and the socket is
  created user-only. On the socket, each connection carries one request frame and gets one result or error frame
  back. The socket has its own operations: the `job.*` and `cua.*` that `serve` forwards, plus `cua.cancel`, and
  for the CLI `hello` (pid, version, jobs, whether launchd or systemd started it, desktop), `access`
  (permissions.rs) and `shutdown`.
- If no supervisor answers, `serve` starts `hands supervise --detached` in a new session (`setsid`), with its
  stdio on `/dev/null` and `supervisor.log`, so it outlives the connection. `hands install` runs it as a systemd
  user unit or LaunchAgent instead. Only one supervisor runs per state dir, because it holds `supervisor.lock`. A
  service-managed supervisor waits for that lock and takes over when an on-demand one exits.
- Each job has a directory `jobs/<readable key>-<hash>/` containing `job.json` (the status record, without the
  environment), `output.log`, `runner.lock` and `exit.json`.
- The supervisor starts the job through `hands __job-runner`. The runner leads the job's process group, holds
  `runner.lock` while it lives, ignores SIGHUP, SIGINT, SIGTERM and SIGQUIT (the command gets the defaults back),
  and writes the exit status to `exit.json`. Because of this, a job survives a supervisor restart (an upgrade, a
  crash, `hands install`) and keeps its exit code. A new supervisor adopts running jobs by watching their lock.
  Jobs that ended while no supervisor was watching and left no `exit.json` (for example, after a reboot) become
  `failed`.
- **Retention:** a finished job is deleted 7 days after it ended, or earlier once more than 200 jobs have finished
  (the oldest go first). Retention runs when the supervisor starts and every hour after that. Running jobs are
  never deleted. After deletion, the key is free again.
