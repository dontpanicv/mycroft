# Design direction: Liquid Glass × grep.ai

Two references, one rule: **the content is a terminal; the chrome is glass.**

- **grep.ai** gives the content layer its voice: near-black canvas, monospace headlines, uppercase tracked labels, hairline borders, square corners, a dotted grid, one indigo accent. It reads like an engineer's console.
- **iOS 27 Liquid Glass** gives the controls their physics. The composer, buttons, sheets and bars float above the content as glass. They blur and lift the terminal underneath and press in when touched. Since the screen is the agent's own web code ([ADR 0009](decisions/0009-self-editable-web-ui.md)), the glass is CSS (`.glass` in `agent/generation-0/ui/style.css`): backdrop blur and saturation, a lit top edge, a specular gradient and press scaling.

## Tokens (captured from grep.ai, 18 Oct 2026)

| Token | Value | Use |
|---|---|---|
| `canvas` | `#0B0B0D` (lab 2.75) | App background. Dark-first; light mode inverts to `#F7F7F8`. |
| `ink` | `#F4F4F5` | Primary text |
| `ink-muted` | `#AAAAB4` | Secondary text, metadata |
| `hairline` | `#FFFFFF` at 10–12% | 1 px borders, dividers, card outlines |
| `accent` | `#5147EF` | Primary actions, focus, running state |
| `accent-soft` | `#9D93FF` (lavender) | Highlighted words in headlines, links, tool names |
| `grid` | `#FFFFFF` at 6%, 1 px dots, 24 pt pitch | Empty states, the screen's background |

**Type:** JetBrains Mono for headlines, labels, code, tool calls and numbers. Labels are uppercase with +8–12% tracking. Schibsted Grotesk for body text and assistant prose. Both are OFL; bundle them.

**Shape:**
- Content cards are **square** (radius 0) with hairline borders, as on grep.ai.
- Glass controls are **capsules and continuous rounded rects**, as iOS draws them.
- The two never mix: square means content, round means control.

## Screens

No decoration that repeats what is already on screen or is the same everywhere: no slogans, no row numbers, no
labels on the user's own messages, no model or `PHONE` tags on every thread, no status text the progress line and the
run capsule already show.


- **Threads.** A list of hairline rows: an unsent draft, pinned threads, active threads, then a collapsed "Settled (N)" shelf of slim rows. Each row shows the title in mono, when it last moved, a machine badge only when it runs on one (`HETZNER`, `MAC`), and what needs the user (`WORKING`, receding; `FAILED`; `DONE`, unread). With nothing open, the list says "All settled" (or "No threads yet") with a New thread button. Swipe left to settle, long-press for pin, rename and archive. A floating **+** opens a new thread's draft.
- **Thread.**
  - The transcript is the terminal: user turns are bordered blocks, assistant prose is grotesk, and tool calls are mono rows such as `01 bash  ls -la  ✓ 0.4s` that expand into output.
  - The composer is a glass capsule at the bottom: the field, the mic and send (a machine badge above it only when the thread runs on one). While listening, a row above shows a red dot, a timer and one line saying what to do ("‹ Slide to cancel" while held, with a lock above the mic to slide up to); the words appear live in the field, and ✕ clears it. While a run works, a glass capsule above shows "Working 1m 05s" and "N queued", and send queues (or steers).
  - A finished run folds into "Worked for 1m 05s · 4 steps"; the answer keeps Copy, Fork and its time.
  - A run shows a thin indigo progress line under the nav bar and a Live Activity on the lock screen.
- **Machines.** Hands hosts as square cards showing hostname, OS, latency and running jobs. Pairing is a glass sheet.
- **Self.** The agent's generations: diff, self-test result, active, rollback. In mono, like a git log.

## Motion

- Streaming text appears token by token without a cursor bounce. The tool-call row number ticks while running.
- Loops are slow and seamless: the spinner turns once a second, the run glow glides off both edges in 2.8 s.
- Respect Reduce Motion: slides and zooms become fades, press scaling stops, and the send ring shows full at once. Activity indicators keep their normal pace, as iOS's do. A loop squeezed to near-zero duration strobes.
- Respect Reduce Transparency: glass falls back to an opaque `#141418` with a hairline border.
