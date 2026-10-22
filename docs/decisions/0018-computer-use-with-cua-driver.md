# 0018 · Computer use with Cua Driver, linked into `hands`

**Status:** accepted, implemented (21 Oct 2026). Supersedes [0006](0006-computer-use-with-jev.md) and the desktop
bullet of [0005](0005-hands-daemon.md).

**Context.**
- Computer use worked (M6), but as a loop of its own: for each step of `desktop_do` the phone asked Jev (typesafe.ai's
  model, its key in the phone's Keychain) for the next `ui.observe` / `ui.act` / `ui.screenshot`. The thread's model
  handed the task over and saw only the outcome.
- The desktop lived in a second program, Mycroft Hands.app, with its own LaunchAgent
  (`dev.mycroft.hands-desktop`), its own zip served by the phone (`MycroftHands.zip`, `hands install --desktop-zip`),
  its own permissions (`hands desktop permissions`) and its own protocol over `desktop.sock`.
- [Cua Driver](https://github.com/trycua/cua) (MIT, Rust) is a background computer-use driver: per-window
  accessibility tree and screenshot reads with `element_token`s (`s0000002a:11`), diff re-reads (`since`),
  `run_steps` batches with checks, `run_script`, `verify_state`, input that doesn't move the user's pointer or switch
  apps, and an agent cursor overlay. Its Rust crates can be linked as a library.
- `hands` already runs as a LaunchAgent. Started by launchd, it is its own responsible process, so macOS can grant
  Accessibility and Screen Recording to "hands" itself.

**Decision.**
- **Cua Driver is linked into `hands`**: the `cua-driver-sdk` crate, with `cua-driver-core`, `cursor-overlay` and
  `platform-macos`, pinned to the tag `cua-driver-rs-v0.38.0`. macOS only: the Linux builds are static musl, and Cua's
  Linux crates link X11. Nothing else is installed on the Mac: no CuaDriver.app, no `cua-driver` CLI.
- **It runs in the supervisor launchd starts** (`dev.mycroft.hands`, `hands supervise --listen`), created once at
  startup with `CuaDriver::try_create_service_for_host`, as Cua's own service does, with `host_owns_permission_ux`.
  Its agent cursor takes the main thread's AppKit loop; the supervisor accepts connections on another thread. A
  supervisor that `serve` started on demand has no desktop (`not_service`).
- **Two operations carry Cua's MCP surface unchanged** (hands/docs/jobs.md). `cua.tools` returns Cua's `tools/list`
  entries and its server instructions, less `parse_visual_regions` (it needs Cua's perception model, which `hands`
  doesn't link) and the Computer History tools (off). `cua.call { name, arguments }` returns Cua's `CallToolResult`.
  `serve` forwards both to the supervisor over `supervisor.sock`, like `job.*`, with the client's name and a call id; a
  cancel aborts the driver call. Each client has one Cua session, kept across reconnects so element tokens stay valid.
- **The thread's own model drives.** The phone offers Cua's tools under their own names, descriptions and schemas,
  plus a `machine` property (`CuaTools.swift`). The catalog is bundled (`cua-tools.json`) and replaced by a newer one
  when a Mac has a newer driver. Four are always offered, Cua's own loop: `list_windows`, `launch_app`, `get_window_state` and `run_steps`, whose steps are the single actions; the rest wait for `tool_search`. (Offering 15 cost each request 53 KB of schemas, about 11k tokens, and tripled a thread's first request.) Cua's
  instructions go into the system prompt. Read-only tools replay after a restart and retry on a fresh connection; the
  others don't.
- **Risky actions stop for the user.** A `beforeTool` hook stops an action that would type or choose a destructive
  word (delete, send, pay, quit, sign out, ...), whose `element_token` points at an element labelled with one (from
  the machine's recent reads), that presses cmd+q or cmd+delete, or that calls a tool Cua marks destructive other
  than the input tools, which are judged by their target. The model asks the user and repeats the call with
  `confirmed: true`, which the hook strips before Cua sees it.
- **Every permission belongs to `hands`.** `hands permissions` asks for Accessibility and Screen Recording through the
  service's supervisor, like the folders and the network. The supervisor checks the two in a fresh child
  (`hands permissions --probe`) and says whether it sees the grant itself. When it doesn't, the walkthrough restarts
  the service, because macOS tells a process about a Screen Recording grant only once it restarts.
- **Removed:** Jev and its key, `desktop_do` and the `ui_*` tools, Settings → Desktop control, Mycroft Hands.app,
  `ui.*`, `desktop.sock`, `--desktop-zip`, `hands desktop`, and the phone's `MycroftHands.zip`. `hands install` removes
  the old helper and its LaunchAgent where an earlier version installed them.

**Trade-offs:**
- The macOS `hands` binary grows: Cua's runtime, tokio, and QuickJS for `run_script`.
- The first build clones Cua's git repository (about 630 MB); Cargo keeps it after that.
- Cua's background input uses private SkyLight APIs, which a macOS update could break.
- The two grants survive updates only when releases are signed with an Apple Development identity; signed ad hoc,
  macOS asks again after each update.
- Commands `hands` runs are its children, so they inherit Accessibility and Screen Recording along with the folders:
  a shell command can now read or drive the screen too. The pairing already gives the phone that much.
- The confirmation hook is on the phone, and only as good as its word list and the labels it has seen.
- Cua's perception (`parse_visual_regions`) and Computer History are deliberately off, so `hands` links no model and
  offers fewer tools than Cua does.
- No desktop on Linux.
