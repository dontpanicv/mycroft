# 0015 · The screen calls the agent's tools; generations hold only what the agent changed

**Status:** accepted, implemented (21 Oct 2026). Amends [0004](0004-self-modification-by-generations.md) and
[0009](0009-self-editable-web-ui.md).

**Context.** The user asked Mycroft to show the CPU usage of every machine above the thread list. Mycroft could change
its screen, but the screen could only list machines and check that they were online: the tools that reach machines
belonged to the agent. So Mycroft said it needed an app update, and went as far as editing the app's Swift source on
a Mac. Two more things were in the way:
- Each generation kept a full copy of every file, so after an app update the active generation still showed the old
  screen code and read an old `SELF.md` (which said only `extension.js` could change).
- Nothing told the agent what its screen could reach.

**Decision.**
- **`tools.call`** (`Agent/ScreenTools.swift`) runs any of the agent's tools for the screen: native (hands_*, ui_*,
  show, self_*), the active generation's JavaScript tools, and code mode (a `codemode` script that calls the others).
  A tool runs inside a durable call, which exists only in a model's turn, so the screen's calls go through a hidden
  conversation whose model is local (a FauxProvider responder): it answers each request with exactly the calls the
  screen asked for, in parallel, and ends the turn when their results are in. Tools run exactly as they do for the
  agent, and no real model is involved. Requests run one at a time; each resets the conversation's context.
  `tools.list` gives every tool with its schema.
- **`machines.exec`** runs a quick command on a machine directly (bash, at most 60 s, first 16 KB of output) and stores
  nothing. `tools.call` is stored like any tool call, so it suits actions and occasional reads; anything that refreshes
  uses `machines.exec`.
- **Code mode** (`Extension.codemode()`) is installed for the agent too.
- **The agent knows.** The `self` prompt section and `ui/README.md` say the screen can call tools and machines, so a
  screen feature that needs live data needs no app update, and the agent must not edit the app's source to change
  itself.
- **`SELF.md` and `ui/README.md` belong to the app.** They describe the native host, so every generation reads the
  app's copy and the agent can't write them.
- **A generation holds only what the agent changed** (amends 0004). A draft starts from the active generation's own
  files, and everything else comes from the app's bundled generation 0, so app updates reach every generation. At
  start, copies identical to the app's, and all of generation 0, are removed from older generations.

**Trade-offs:**
- Every `tools.call` adds a few entries to the database (calls and results), kept forever like other conversations'.
- Overlays can't delete an app file: a generation can only replace it.
- A generation made before this holds old copies of the files it inherited. Copies that equal the current app's are
  pruned; older ones still hide updates. On the developer's phone they were replaced by hand once.
