# 0003 · Default model: Sol 6.1 on the ChatGPT subscription

**Status:** accepted

The default provider is `openai-codex` with model `gpt-6.1-sol`. Login uses the OpenAI device-code flow (as pi-ai implements it). Tokens are stored in the keychain.

**Development:** a script imports `~/.codex/auth.json` into simulator builds.

**Caution:** don't share one refresh token between Codex and Mycroft on a real device. The two clients rotate it and log each other out.
