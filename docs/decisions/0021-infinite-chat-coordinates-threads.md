# 0021 · The infinite chat coordinates threads

**Status:** accepted, implemented (23 Oct 2026).

**Context.**
- The infinite chat ([0020](0020-infinite-chat.md)) is where the user talks to Mycroft every day. They want to hand
  work from it to threads ("create a thread for…", "let an agent do…") and ask how that work is going.
- T3 Code gives its agents tools for this: `t3_thread_launch` (a top-level thread with a task message),
  `delegate_task` (a child that gets only the brief), `t3_thread_list`, `t3_thread_read` (status and the latest
  messages, paged), `t3_thread_send` (follow-up or steer), `t3_thread_wait`, `t3_thread_interrupt`. Every T3 agent has
  them; what keeps it from starting threads on its own is its instructions ("only when the user explicitly asks").
- Pi Durable selects extensions per conversation: `Settings.extensions` is the default selection, and a conversation
  can add others (`AgentChange.extensions`).

**Decision.**
- **Five tools, only in the infinite chat** (`Agent/ThreadTools.swift`, extension `mycroft.threads`): `thread_start`
  (a new thread whose first message is the brief, running at once), `thread_list`, `thread_read`, `thread_send`
  (follow-up, or steer), `thread_stop`. They work through `AppModel`, so a thread started this way is an ordinary
  thread: in the list, running in the background, on the default model.
- **The default selection leaves out `mycroft.threads` and `mycroft.memory`** (`AppModel.infiniteOnly`); the infinite
  chat adds them when it is made, or at launch if it doesn't have them yet. A fork of the infinite chat goes back to
  the default. Regular threads see neither the thread tools nor `memory_zoom`.
- **Only when the user asks**, as in T3: the extension's prompt section and each tool's description say to start,
  message or stop a thread only when the user's message asks for it, and to check on threads when the user asks.
  There is no check of the user's words: phrasing, spoken especially, varies too much.
- A thread the infinite chat started has it as its `parent`; the thread screen says "Started from Mycroft ∞". Answers
  link threads as `[title](#/t/ID)`, which the screen's markdown opens.

**Not built:** a message to the infinite chat when a thread finishes (T3 queues one, which starts a run: Mycroft would
act on its own), waiting for a thread, choosing a thread's model, worktrees, archiving.
