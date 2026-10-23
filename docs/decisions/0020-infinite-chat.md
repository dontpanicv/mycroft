# 0020 · The infinite chat, after UniiChat

**Status:** accepted, implemented (23 Oct 2026).

**Context.**
- Threads end: each is a task, and a new one starts from nothing. The user also wants one chat that never ends, where
  Mycroft remembers what was said weeks ago.
- [UniiChat](https://github.com/VictorTaelin/UniiChat) (Apache-2.0) is such a chat. Over its messages grows a binary
  tree: node (l, i) covers messages i·2^l ..< (i+1)·2^l, a leaf is its message in one line of at most 512 bytes, a node
  above merges its two halves. Every node is built in the background as soon as its halves are, and kept on disk (a log
  of nodes and an index of fixed slots). Each call sees a view: lines covering the chat, recent ones a message each, old
  ones fewer and broader, then the new messages whole. Past its high (128 KB), the view merges its most due sibling pairs
  whose parent is built, down to half, so it changes only at its end between batches and each call reads most of its
  input from the provider's prompt cache. `zoom(id, n)` opens a line into the two it was made from, down to the message.
- Mycroft already has a chat engine: Pi Durable keeps every entry, and a `beforeRequest` hook can replace the messages
  of one model request.

**Decision.**
- **One thread, marked `infinite`** in `mycroft.threads`, made once at launch. It is an ordinary Pi conversation with
  everything a thread has (composer, voice, conversation mode, queue and steer, fork, background runs), shown by a
  "Mycroft ∞" row above the thread list instead of in it. It can't be archived or renamed.
- **UniiChat's tree and view, natively** (`Agent/Memory.swift`, so a self-edit can't break the memory). A leaf is a
  message of a Pi entry (user, answer, tool result); the tree's files (`Documents/memory/<conversation>/`) are
  UniiChat's: `main.index` points each message at its entry, `tree.log` and `tree.index` keep the nodes, `view.json` the
  views. After each run (and at launch) the new messages are indexed and their nodes built, eight at a time, on Sol 6.1
  at low effort, each with the summaries' own view (32 KB) up to it.
- **Every request of the chat sees the view** (`beforeRequest`): the lines before the run, then the run whole (from the
  user message after the last final answer). A request waits for the leaves before its run; a failed summary fails it
  with the reason, and the next message tries again.
- **Pi's transcript is trimmed**: since the model never sees it, Pi's token thresholds never come, so past 200 entries
  the chat compacts after a run, with a fixed summary and no model call. The screen shows the transcript since then,
  under an "Earlier · in memory" divider.

**Trade-offs:**
- About one summary call per message (a leaf whose message is longer than a line, and a merge per node above), each
  reading up to 32 KB of view, mostly from the cache.
- UniiChat pages a long message into several leaves; here a leaf reads at most 32,000 characters of its message, and
  `memory_zoom` gives the whole message a page at a time.
- Not taken from UniiChat: imports of other chats, the `date` tool, goals, agents, images in the view.
- Scrolling back past the divider on the screen and search over the memory are not built.
