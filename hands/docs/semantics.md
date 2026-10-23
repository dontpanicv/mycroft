# Semantics

> Derived from pi-env's semantics (MIT, see [../NOTICE](../NOTICE)), trimmed to the operations `hands` keeps
> ([decision 0019](../../docs/decisions/0019-drop-pi-env-compat.md)). The reference is Node on the remote machine, as
> Durable's `NodeExecutionEnv` uses it.

## Split of work

| Concern | Where |
|---|---|
| Path resolution: `~` (the `home` of `hello`), relative paths | the phone |
| Reading a file: `open`, `pread` in chunks until a short read, `close`; size limits and decoding | the phone |
| System calls, processes, spill files, listings | daemon |
| Command output decoding: per stream, WHATWG UTF-8, only a leading byte-order mark dropped | daemon (`encoding_rs`) |

## Rules the standard libraries do not follow

- Recursive `mkdir`: an existing directory is fine, an existing file fails with `EEXIST`, a file in the way of a parent
  fails with `ENOTDIR`. Writes create missing parents this way.
- `tmpdir`: `TMPDIR`, `TMP`, `TEMP`, then `/tmp`, trailing slash removed.
- `open` opens any file like Node's `open(path, "r")`: `/dev/null` reads empty, a FIFO blocks until it has a writer,
  and a directory opens but fails when read.
- `listFiles` has no Node counterpart. Unlike `fd`, symbolic links are not followed; unlike `git ls-files`, a tracked
  file that matches an ignore rule is left out.

## Commands

- A string runs through the shell: a configured `shellPath` that does not exist (following links) fails with
  `shell_unavailable`; otherwise `/bin/bash`, `which bash`, then `sh`, with `-c`. An argv array runs its program
  directly, searched on `PATH` like `execvp`.
- The working directory must exist (`spawn_error`).
- Environment: with `inheritEnv` (default), the daemon's environment, then `env`; without it, only `env`. The daemon's
  environment is the service's, which `hands install` gives the `PATH` of the shell it ran in.
- Each command gets a new session (process group), default signal dispositions and an empty signal mask. Timeout,
  abort and a `kill` cancel kill the group with `SIGKILL`.
- After the process exits, output is still collected until both pipes end, or 100 ms pass without output; the timeout
  still applies meanwhile. The pipes are closed when the command settles, even if a descendant keeps them open.
- An abort settles as `aborted`; a `kill` cancel kills without aborting, so the command settles with exit code 137.
- A process killed by a signal reports `128 + signal`.
- Spill: once the output crosses `spill.afterBytes` or `spill.afterLines` (counted over raw chunks in arrival order),
  the complete raw output goes to `pi-output-<uuid>.log` in a fresh `tmp-` directory.
