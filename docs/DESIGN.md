# Design direction: Liquid Glass × grep.ai

Two references, one rule: **the content is a terminal; the chrome is glass.**

- **grep.ai** gives the content layer its voice: near-black canvas, monospace headlines, uppercase tracked labels, hairline borders, square corners, a dotted grid, one indigo accent. It reads like an engineer's console.
- **iOS 27 Liquid Glass** gives the controls their physics. The composer, buttons, voice orb, sheets and bars float above the content as glass. They blur and lift the terminal underneath and press in when touched. Since the screen is the agent's own web code ([ADR 0009](decisions/0009-self-editable-web-ui.md)), the glass is CSS (`.glass` in `agent/generation-0/ui/style.css`): backdrop blur and saturation, a lit top edge, a specular gradient and press scaling.

## Tokens (captured from grep.ai, 18 Oct 2026)

| Token | Value | Use |
|---|---|---|
| `canvas` | `#0B0B0D` (lab 2.75) | App background. Dark-first; light mode inverts to `#F7F7F8`. |
| `ink` | `#F4F4F5` | Primary text |
| `ink-muted` | `#AAAAB4` | Secondary text, metadata |
| `hairline` | `#FFFFFF` at 10–12% | 1 px borders, dividers, card outlines |
| `accent` | `#5147EF` | Primary actions, focus, running state |
| `accent-soft` | `#9D93FF` (lavender) | Highlighted words in headlines, links, tool names |
| `grid` | `#FFFFFF` at 6%, 1 px dots, 24 pt pitch | Empty states, the background behind the voice orb |

**Type:** JetBrains Mono for headlines, labels, code, tool calls and numbers. Labels are uppercase with +8–12% tracking. Schibsted Grotesk for body text and assistant prose. Both are OFL; bundle them.

**Shape:**
- Content cards are **square** (radius 0) with hairline borders, as on grep.ai.
- Glass controls are **capsules and continuous rounded rects**, as iOS draws them.
- The two never mix: square means content, round means control.

## Screens

- **Threads.** A list of hairline rows. Each row shows the title in mono, the last line in grotesk, a status tag (`RUNNING`, `WAITING`, `DONE`) and the machine badge (`PHONE`, `HETZNER`, `MAC`). The tab bar and a floating **+** are glass.
- **Thread.**
  - The transcript is the terminal: user turns are bordered blocks, assistant prose is grotesk, and tool calls are mono rows such as `01 bash  ls -la  ✓ 0.4s` that expand into output.
  - The composer is a glass capsule at the bottom with model chip, machine chip, attach and voice buttons.
  - A run shows a thin indigo progress line under the nav bar and a Live Activity on the lock screen.
- **Voice.** A full-screen dotted grid with a glass orb that reacts to audio level. The live transcript is in mono. Running tool calls appear as a numbered list (`01 02 03`), as in grep.ai's "how it works" list. Tap the orb to interrupt.
- **Machines.** Hands hosts as square cards showing hostname, OS, latency and running jobs. Pairing is a glass sheet.
- **Self.** The agent's generations: diff, self-test result, active, rollback. In mono, like a git log.

## Motion

- Glass morphs between composer ↔ voice orb (`glassEffectID` with namespace transitions).
- Streaming text appears token by token without a cursor bounce. The tool-call row number ticks while running.
- Loops are slow and seamless: the spinner turns once a second, the run glow glides off both edges in 2.8 s.
- Respect Reduce Motion: slides and zooms become fades, press scaling stops, and the voice orb brightens instead of
  growing. Activity indicators keep their normal pace, as iOS's do. A loop squeezed to near-zero duration strobes.
- Respect Reduce Transparency: glass falls back to an opaque `#141418` with a hairline border.
