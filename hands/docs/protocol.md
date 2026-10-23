# Wire protocol

> Derived from pi-env's protocol 1 (MIT, see [../NOTICE](../NOTICE)), trimmed to what the Mycroft app sends
> ([decision 0019](../../docs/decisions/0019-drop-pi-env-compat.md)). `hands` adds the operations in
> [jobs.md](jobs.md): `job.*`, and on macOS `cua.tools` and `cua.call` (Cua Driver's tools).

Version 1. The phone reaches `hands` through the paired listener ([pairing.md](pairing.md)): each binary WebSocket
message is one frame, and the listener passes frames to and from a `hands __serve` process it starts for that
connection, over the process's stdin and stdout. stderr is diagnostic text for the log only. From its first byte,
stdout carries only frames.

## Frames

Every frame, in both directions:

```text
u32 length      bytes after this field
u8  type
u32 id          request id; 0 for frames that belong to no request
u32 jsonLength
json            UTF-8 JSON object, jsonLength bytes
bytes           raw payload, the remaining length - 9 - jsonLength bytes
```

All integers are big-endian. A frame is at most 16 MiB; larger transfers are split by the client. A request whose JSON
does not parse, or whose `op` is unknown, gets an `EINVAL` error; framing errors end the connection.

| type | name | direction | meaning |
|---|---|---|---|
| 1 | request | client → daemon | `json.op` names the operation |
| 2 | result | daemon → client | success of request `id`; the request is finished |
| 3 | error | daemon → client | failure of request `id`; the request is finished |
| 4 | event | daemon → client | progress of a running request (`exec` output), not finishing it |
| 5 | cancel | client → daemon | cancel request `id`; see below |
| 6 | ping | both | liveness; the receiver ignores it |

Errors are `{ code, message, syscall?, path? }`. `code` is a Node-style error code (`ENOENT`, `EISDIR`, ...) or one
of the execution codes `shell_unavailable`, `spawn_error`, `timeout`, `aborted`, `unknown`. Messages are diagnostic;
only codes are part of the contract.

Paths are absolute JSON strings; the client resolves relative paths and `~` before sending. File contents and output
travel as raw payload bytes.

## Cancellation

A cancel names one request. The daemon registers each request before running it, so a cancel sent right after its
request is never lost. `exec` kills the command's process group and finishes with `aborted`; `{ mode: "kill" }` kills
without aborting, so the command finishes with the killed process's status. `listFiles` stops between entries, and
`job.wait` and `cua.call` between slices, with `aborted`. Other operations are short and finish normally.

## Scheduling

Each operation has one lane. `exec`, `job.wait` and `cua.call` run on threads of their own, as they last or wait;
everything else runs on a fixed pool of worker threads. Results, errors and pings are sent before queued command
output, and results with payloads above 64 KiB queue behind output too, so a slow link delays bulk data, not replies.
Output of a command without an output window waits while more than 4 MiB of output is unsent, which slows the command
as a full pipe would.

## Liveness

The daemon sends `ping` every 5 seconds, which the listener passes on like any frame; the phone treats a connection
that sends no frame for about 20 seconds as dead.
The daemon kills every process group it started and exits after 30 seconds without receiving any bytes, or when stdin
ends (the listener closes it when the connection ends). A dropped connection therefore stops `exec` commands, not
jobs. Handles belong to the daemon that opened them, so after a reconnect requests on them fail with `EBADF`.

## Operations

`hello { protocol }` → `{ protocol, version, os, arch, home, tmpdir, cwd, pid, features, cua }`. The first request.
`version` is the `hands` release; `os` and `arch` are Rust's `std::env::consts` values (`macos`, `linux`; `x86_64`,
`aarch64`); `tmpdir` follows Node's `os.tmpdir()` rules; `cwd` is the daemon's working directory (the user's home).
`features` lists the operations beyond the first six below: `listFiles`, the `job.*` operations, and on macOS
`cua.tools` and `cua.call`. `cua` is `{ version }` of the linked Cua Driver on macOS, `null` elsewhere.

File operations take `{ path }` (and the listed fields) and return `{}` unless noted:

| op | fields | result |
|---|---|---|
| `write` | `append`, payload | creates missing parents like Node's recursive `mkdir`, opens like `writeFile` (`w`) or `appendFile` (`a`), and writes the payload |
| `open` | | Node's `open(path, "r")` of any file, blocking: `{ handle, stat }` with `stat` an `info`, or `{ handle, statError }` |
| `pread` | `handle`, `offset`, `length` | payload of up to `length` bytes at `offset` (at most the frame limit less 64 KiB); fewer only at the end of the file |
| `close` | `handle` | |

`info` is `{ name, kind, size, mtimeSec, mtimeNsec, dev, ino }` with `kind` one of `file`, `directory`, `symlink`,
`other`. Handles are numbers, valid until `close` or the end of the connection; opening more than 4096 fails with
`EMFILE`. An unknown or closed handle fails with `EBADF`.

`listFiles { path, hidden?, gitignore?, exclude?, maxEntries?, maxBytes?, timeoutMs? }` lists the tree below the
directory `path`: files, directories and symbolic links, which are not followed; other kinds of files are left out,
and entries that cannot be read are skipped. The payload holds one record per entry: a kind byte (`f` file, `d`
directory, `l` symbolic link), the path relative to `path` with `/` separators as UTF-8 (names that are not UTF-8 get
replacement characters), and a NUL byte. Records come depth first, siblings in byte order of their names. The result
is `{ count, truncated }`. Entries named `.git` and the names in `exclude` are skipped with everything below them.
`hidden` (default true) includes names starting with `.`. `gitignore` (default true) skips, inside git work trees,
what the `.gitignore` files of `path`, its subdirectories and its parents, `.git/info/exclude` and the global excludes
file ignore, using the `ignore` crate of `fd` and ripgrep. The listing stops with `truncated: true` at the first entry
beyond `maxEntries` (default 50 000), beyond `maxBytes` of payload (default 4 MiB, at most the frame limit less 64
KiB), or after `timeoutMs` (default 10 000). A missing `path` fails with `ENOENT`, a file with `ENOTDIR`.

`exec { command | argv, cwd, env?, inheritEnv?, shellPath?, timeoutMs?, spill?, window? }` runs a shell string or an
argv array. While it runs, `event` frames `{ kind: "output", stream, skipped? }` carry decoded output text as UTF-8
payload. With `window { maxBytes, maxLines, minIntervalMs, bytesPerSecond }`, output is coalesced and paced, at most
one output frame per command is unsent, and output followed by more than the window is replaced by
`skipped { bytes, newlines, endsWithNewline }` on the next event, which carries all output after it. The result is
`{ exitCode, spillPath? }`; failures are errors with codes `timeout` or `aborted` (carrying `spillPath`),
`shell_unavailable`, `spawn_error`, or `unknown` (spill failure). The phone's quick reads use `exec`; the agent's
commands run as jobs ([jobs.md](jobs.md)), which outlive the connection.
