# 0004 · Self-modification by generations

**Status:** accepted (module format: open)

The agent never edits the generation that is running. It writes generation n+1 and self-tests it in a scratch `JSContext`. The host then atomically flips `active`, swaps the main context and Pi Durable resumes. A crash loop rolls back to the last good generation.

**Open question:** how source is laid out and loaded on device. The candidates:
- a pure-JS type stripper plus a tiny CommonJS-style module registry provided by the host; or
- shipping prebundled JS and editing that.

To be decided in M4 with measurements.
