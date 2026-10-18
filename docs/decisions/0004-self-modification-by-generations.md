# 0004 · Self-modification by generations

**Status:** accepted, implemented (18 Oct 2026)

The agent never edits the generation that is running. It writes generation n+1 and self-tests it in a scratch `JSContext`. The host then atomically flips `active`, swaps the main context and Pi Durable resumes. A crash loop rolls back to the last good generation.

**As built:**
- A generation is a folder with one CommonJS pi-durable extension (`extension.js`) and the agent's guide (`SELF.md`). The agent writes plain JavaScript, so no on-device compiler is needed.
- The pi-durable/pi-ai/chord bundle itself ships fixed inside the app (via PiDurableKit). The agent changes its own behaviour, prompt and JS tools, not the runtime under it.
- Activation is `harness.install(Extension("mycroft", javaScript:))` on the live harness:
  - a load error leaves the old generation in place;
  - on success, the current phase finishes on the old code and the next one runs the new code.
- Native capabilities stay in Swift extensions (`mycroft.self` today; hands and desktop control next).
