# 0002 · The agent runs in JavaScriptCore, the shell in SwiftUI

**Status:** accepted

Pi Durable runs in an in-process `JSContext`. The thread, chat and voice UI is native SwiftUI.

**Why:**
- The background spike kept a `JSContext` working for 10+ minutes after the app left the foreground, including a self-edit and context swap.
- WKWebView executes in a separate WebKit process that iOS throttles in the background.
- PiDurableKit shows Pi Durable works on JSC.
- Liquid Glass is native-only.

**Trade-offs:**
- No JIT. Acceptable, because the agent is I/O-bound.
- The native chrome itself is not self-modifiable. Agent-authored UI goes into a web canvas inside messages.
