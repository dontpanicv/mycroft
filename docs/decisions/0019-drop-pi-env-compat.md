# 0019 · `hands` drops pi-env compatibility and SSH

**Status:** accepted, implemented (22 Oct 2026). Supersedes the pi-env-compatibility and SSH parts of
[0005](0005-hands-daemon.md) and the SSH transport (point 5) of [0008](0008-hands-transport-pairing.md).

**Context.**
- 0005 kept `hands` a superset of pi-env's daemon, so pi's `RemoteExecutionEnv` could use it over SSH, and 0008 kept
  `hands serve --stdio` over `ssh` as a second transport for servers with keys set up.
- The Mycroft app is the only client, and it only ever connects through the paired TLS listener. It sends `hello`,
  `write`, `open` (`mode: "read"`), `pread`, `close`, `listFiles`, `exec`, the six `job.*` operations, `cua.tools`
  and `cua.call`.
- Everything else was carried for a client nobody runs: directory handles (`opendir`, `readdir`), chunked writes
  (`writeChunk` and the per-handle ordering behind it), `scanLines`, `watch` (a port of Durable's `NodeFileWatcher`,
  and the `notify` dependency), `pty` with `ptyWrite`, `ptyResize` and `ptyForeground`, and the path operations
  (`lstat`, `realpath`, `rename`, `rm`, `mkdir`, `mkdtemp`, `truncate`, `fsync`, `fstat`). About 1,900 lines, with
  Windows-shaped code in a crate that refuses to build anywhere but macOS and Linux (`driveCwds`, the WSL
  `command_on_stdin` shell, no-op process hooks).
- The SSH path kept a second way in with its own assumptions (the `PI-ENV <token>` sync line for shells that print at
  login, the job environment "of the SSH login"), and documentation that called it the usual one.

**Decision.**
- **One transport: the paired listener.** `hands serve` and `--stdio` are gone as commands; `hands` with no command
  prints its usage. The listener still runs one child per connection, now the internal `hands __serve` (like
  `hands __job-runner`), so a crash in one connection's requests ends only that connection. There is no sync line:
  the child's stdout carries frames from its first byte.
- **The protocol is what the app sends.** `hands/docs/protocol.md` describes the operations above and nothing else;
  `hello` drops `driveCwds` and `separator`, and `open` always opens for reading, returning `{ handle, stat }`.
  Unknown operations fail with `EINVAL`, as before.
- **Operations are an enum.** `serve.rs` parses each request into one `Op`, which gives its name, its lane (the worker
  pool, or a thread of its own for `exec`, `job.wait` and `cua.call`) and whether `hello.features` lists it. The
  supervisor socket has its own, separate `SupervisorOp`, whose `Hello` is the supervisor's status, not `serve`'s `hello`.
- **pi-env remains the origin**, credited in `hands/NOTICE`: the framing, `exec`, `listFiles` and the output window
  are still its code.

**Consequences.**
- pi's `RemoteExecutionEnv` can no longer use `hands`. Servers are reached like Macs: install with the phone's
  command, pair, and connect through the listener (with Tailscale or NetBird across networks).
- With no SSH login to inherit an environment from, commands and jobs get the service's. `hands install` therefore
  writes the `PATH` of the shell it runs in into the LaunchAgent (`EnvironmentVariables`) and the systemd unit
  (`Environment=PATH=…`), so `npm`, `brew`, `cargo` or `gh` are found.
- An operation the app needs later is added to both sides on purpose, with a test, rather than kept in case.
