# 0009 · The screen is part of the agent: a self-editable web UI with hot reload

**Status:** accepted, implemented (19 Oct 2026). Supersedes the "shell in SwiftUI" half of [0002](0002-javascriptcore-agent-runtime.md).

**Context.** The first build drew every screen in SwiftUI. Only the agent's behaviour (`extension.js`) could change itself. Asked to "make Mycroft dark green", the agent could edit a colour file, but nothing else on screen. That misses the point of Pi Durable. Mario's pim reloads the screen as web code ("web > HMR") while durable state keeps the conversation alive. Mycroft should do the same: the agent should be able to change anything you see.

**Decision.** The screen moves into each generation as `ui/`: plain ES modules with Preact + htm and no build step (the agent writes files on the phone). It runs in a full-screen `WKWebView`.

- `mycroft-ui://app/g/<n>/…` serves generation *n*'s `ui/`. A file a generation lacks comes from the app's bundled generation 0. `…/draft/…` serves the draft and `…/lib/…` serves the fixed runtime (Preact, fonts). All generations share one origin, so a page can import a new generation's modules in place.
- **Hot reload.** `boot.js` holds the link to the app and two stores:
  - the app's data: threads, views, sign-in…
  - the screen's own saved state: navigation, drafts.

  On a new generation it imports that generation's `app.js`, unmounts the old tree and mounts the new one. CSS swaps link by link. Changing `boot.js`/`index.html` forces a full page reload, with the UI state saved first. Conversations live in Pi Durable, so nothing is lost either way.
- **Bridge.** The page calls the app with `postMessage({ op, args })` (reply-capable), and the app pushes events (`state`, `view`, `listen`, `pairing`, `hot`). The contract is `agent/generation-0/ui/README.md`, which the agent reads.
- **Safety, in layers:**
  1. `self_activate` renders the draft off-screen first and refuses it on load errors, render errors or uncaught errors. JavaScriptCore names the file and line of syntax errors.
  2. `self_preview` gives the agent a picture of the draft.
  3. If the hot swap fails on the live page, the page keeps its old screen and the generation is rolled back.
  4. A screen that fails to load at launch rolls back to the last good generation.
  5. A native recovery screen appears when the page doesn't load, or when the user shakes the phone.
  6. An injected script that the agent can't edit reports every page error, even when `boot.js` is broken.
  7. A generation is only marked good once its screen has loaded.
- **Native and fixed:** background runs, the Live Activity layout (its colour follows the page's `--accent-soft`), keychain, microphone and speech, the hands connection, the install server, the recovery screen.

**Trade-offs:**
- Liquid Glass becomes a CSS imitation (backdrop blur, saturation, specular edge, press scaling) rather than the system material. It's close, and the price of a screen the agent can rewrite.
- WebKit's form bar above the keyboard is removed with a runtime subclass of the web view's content view, because there's no public switch for it.
- The web view only renders in the foreground. A self-edit made during a background run is activated without the off-screen check; the screen is checked when the user opens Mycroft, and rolled back if it fails.
- A generation that rewrote its `ui/` keeps its own copy. App updates to the bundled screen reach only generations that never edited theirs.
