# iOS host

The native iOS 27 app: the web view that shows the agent's own screen (`Mycroft/Web`, the screen itself is `agent/generation-0/ui`), the agent's generations and native tools (`Mycroft/Agent`, `Hands`, `Desktop`), voice and the background-run controller. The JavaScriptCore runtime is PiDurableKit. See [ARCHITECTURE.md](../docs/ARCHITECTURE.md).

The project is generated with XcodeGen (`project.yml`).

Run `scripts/fetch-fluid-speech.sh` once before building: it downloads the Fluid Speech Mini speech model (~240 MB) into
`ios/Models`, outside git, and the build bundles it for dictation. Without it, the build has no dictation.
`scripts/fetch-phonon.sh` does the same for the conversation voice (~150 MB); without it there is no conversation mode.
