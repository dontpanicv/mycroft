# 0005 · `hands`: a pi-env-compatible daemon with a job supervisor

**Status:** proposed

A single Rust binary for macOS and Linux:
- `hands serve --stdio` over SSH speaks a superset of pi-env's wire protocol (files, exec, PTY, `listFiles`).
- A supervisor (systemd user unit or LaunchAgent) owns long jobs, keyed by tool-call id. Jobs survive the phone disconnecting and can be reattached.
- On macOS, a LaunchAgent in the user's GUI session holds the Accessibility permission and serves `ui.observe` and `ui.act` over a Unix socket.

**Why not pi-env as is:**
- pi-env kills its children when the connection drops for about 30 s, which is fatal when the brain is a phone that sleeps.
- pi-env has no desktop-control operations.

**Why Rust:**
- It shares the pi-env daemon codebase (MIT).
- It produces a static binary.
- It has good AX bindings on macOS via `objc2`.
