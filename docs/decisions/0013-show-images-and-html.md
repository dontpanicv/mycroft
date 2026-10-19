# 0013 · The agent can show images and HTML in a thread

**Status:** accepted, implemented (19 Oct 2026).

**Context.** Threads were text only. Tools could return images (a Mac's screen, a preview of Mycroft's own screen),
but those reached only the model: the transcript kept them inside folded tool output. When a picture, a table or a
diagram would explain better than prose, the agent had no way to put one in front of the user.

**Decision.** One general tool, `show` (`ios/Mycroft/Agent/ShowTools.swift`), and a prompt section telling the
agent it can show, not only write. Nothing in it is about a particular use; the agent decides when seeing beats
reading.

- `show({ image })`: `"latest"` (the newest image any tool returned in this thread), a file path on a paired machine,
  or an https URL. The tool reads it, re-encodes it as a JPEG (at most 2000 px, small enough for the screen) and
  stores it on the result's `details`. `details` reach the screen but not the model, so a shown image costs no tokens
  on later turns; the model gets "Shown to the user: an image, W×H".
- `show({ html })`: the agent's own HTML and CSS. It stays in the call's arguments, and the screen renders it in a
  frame as wide as the phone and as tall as its content.
  - The frame is sandboxed without scripts, and a Content-Security-Policy allows only inline styles and `data:`
    images and fonts, so shown HTML can't run code or load anything from the network.
  - A fragment gets a white page with the system font; a full document keeps its own head.
- In the thread, what was shown stays in view when a finished run folds into "Worked for …", just before the answer.
  An image opens full screen (tap again for full size, to pan); HTML has a full-screen button.

**Trade-offs:**
- No JavaScript in shown HTML: no interactive charts. Inline SVG covers most diagrams.
- An image is stored twice when a tool returned it first (once for the model, once shown).
- `"latest"` is the only way to point at an image a tool returned; the agent can't pick an older one.
