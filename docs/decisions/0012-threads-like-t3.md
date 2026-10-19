# 0012 · Threads like T3 Code: drafts, a Settled shelf, queue or steer, fork; dictation the user starts and stops

**Status:** accepted, implemented (19 Oct 2026). Amends [0010](0010-voice-in-every-thread.md) and
[0011](0011-dictation-parakeet.md).

**Context.**
- Ending a spoken turn on a pause sent messages the user wasn't done with. They want to start and stop dictation
  themselves, like a WhatsApp voice note, and a way to clear the field and start over.
- The thread basics were thin next to T3 Code (pingdotgg/t3code, studied in its mobile and web apps):
  - "New thread" created an empty thread at once, and abandoned ones piled up;
  - the list never put old threads away and didn't say which ones need the user;
  - a message sent while a run worked always steered it; there was no queue, no fork, no rename, no retry.

**Decision.**
- **Dictation** (`Voice/Listener.swift`, `screens/composer.js`). Nothing is sent on a pause; turn detection is gone
  (only the voice level is kept, so Parakeet transcribes again as soon as the user pauses).
  - Hold the mic and talk; release sends. Slide left to cancel, slide up to lock it on.
  - A quick tap also locks it on. While on, the row above the field shows a timer, and offers the trash (cancel);
    the mic (now a stop square) keeps the words in the field to edit; send sends.
  - ✕ in the field clears it, also while listening (the typed text and the words so far; listening goes on).
  - Sending goes through the screen like typed text (`listen.stop` returns the words), so queue, steer and new-thread
    drafts work the same for voice.
- **New thread is a draft** (`#/new`): nothing exists until the first message is sent (`thread.create`). An unsent
  draft is listed as "Draft" at the top of the list, and can be discarded.
- **The list**, top to bottom: the draft, pinned threads, active threads, then **Settled (N)**, collapsed by default,
  10 at a time.
  - A thread settles when the user swipes it left or picks Settle in the long-press menu, or after **three idle days**
    (not while pinned, running, or with an unread answer). Sending to it brings it back; Un-settle restarts the clock.
  - Each row says what needs the user: **Working** (the row steps back), **Failed**, or **Done**: an answer newer than
    the user's last visit.
  - Long-press: Pin, Rename, Settle, Archive (not while it runs). Archived threads have their own screen.
- **While a run works**, send **queues** by default (`Settings → While Mycroft works`); holding send offers the other
  way, **steer**, which reaches the run at its next step. A capsule over the composer shows "Working 1m 05s" and
  "N queued"; the queue sheet steers one now, edits one (back into the composer) or removes it.
  - **Stop** stops the run but keeps the queue, paused; "Resume" sends it. (Pi Durable's `abort()` drops queued
    inputs, so stop aborts only the run's task.)
- **A finished run folds** its thinking and tool calls into "Worked for 1m 05s · 4 steps"; the answer stays, with
  Copy, **Fork** and its time. A fork is a new thread with the history up to that answer, titled "Fork · …" (a
  prefix, so it shows in a narrow row), and links back to its parent. A failed run offers Retry. Tapping the title
  renames.

**Not taken from T3:** snooze, manual ordering, search, PR links, per-thread model settings, editing a queued message
in place (Pi Durable can't update a queued input, so Edit withdraws it and puts it back in the composer).

**Trade-offs:**
- Unread and settled state is Mycroft's own (`ThreadMeta`), and run endings are only seen while RunMonitor follows
  runs (runs started from the app). A thread that is deleted would still be in the database: there is no delete, only
  Archive.
- Auto-settling runs on the screen when the list is shown, so it changes with the clock rather than being stored.
