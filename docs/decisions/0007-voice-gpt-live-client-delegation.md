# 0007 · Voice: GPT-Live with client delegation, audio in the native host

**Status:** proposed

The live model does the talking and delegates real work to Pi Durable through a function call. That call becomes a durable submission, with the call id as its `requestId`. Barge-in steers or cancels the run.

The audio session lives in Swift, so self-reloads of the JS runtime never drop the conversation.
