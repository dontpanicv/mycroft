# 0007 · Voice: GPT-Live with client delegation, audio in the native host

**Status:** superseded by [0010](0010-voice-in-every-thread.md): voice moved into every thread, on the iPhone, and GPT-Live was removed.

The live model does the talking and delegates real work to Pi Durable through a function call. That call becomes a durable submission, with the call id as its `requestId`. Barge-in steers or cancels the run.

The audio session lives in Swift, so self-reloads of the JS runtime never drop the conversation.
