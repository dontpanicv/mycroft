# agent

The agent's own code. It runs inside the iOS host's JavaScriptCore runtime, on top of Pi Durable (via [PiDurableKit](https://github.com/finnvoor/PiDurableKit)).

- `generation-0/extension.js`: the starting behaviour. This is a pi-durable extension in CommonJS: identity and style prompt sections, plus JavaScript tools.
- `generation-0/SELF.md`: the agent's guide to editing itself.

The app bundles `generation-0` and copies it to `Documents/agent/generations/0` on first launch. From then on the agent edits its own copy:

1. It writes a draft.
2. `self_activate` installs the draft into the running harness with `harness.install`, and Pi Durable swaps the extension in place.
3. The draft becomes generation n+1.

If a generation crash-loops on start, the host falls back to the last good one.

Native capabilities (self-editing, hands, desktop control, voice delegation) are Swift extensions in `ios/Mycroft/Agent/`. They are fixed per app build.
