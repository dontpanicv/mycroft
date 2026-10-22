# 0006 · Computer use: AX tree + Jev, decided on the phone

**Status:** superseded by [0018](0018-computer-use-with-cua-driver.md) (21 Oct 2026). Implemented as below for M6.

The loop is observe → decide → act → verify:
1. **Observe:** `hands` returns a compact accessibility tree with element refs.
2. **Decide:** the phone asks Jev (typesafe.ai's system-one model) for the operation *and* its target in one request (the jev-use pattern).
3. **Act:** `hands` performs the action.
4. **Verify:** `hands` observes again to check the result.

The Jev key stays on the phone.

**Later, if latency hurts:** delegate a whole bounded subtask loop to `hands` with a short-lived token.
