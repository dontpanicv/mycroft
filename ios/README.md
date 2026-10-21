# iOS host

The native iOS 27 app: the web view that shows the agent's own screen (`Mycroft/Web`, the screen itself is `agent/generation-0/ui`), the JavaScriptCore runtime host, bridges and background-run controller. See [ARCHITECTURE.md](../docs/ARCHITECTURE.md).

> Status: scaffolding in milestone M1. The project is generated with XcodeGen (`project.yml`).

Run `scripts/fetch-fluid-speech.sh` once before building: it downloads the Fluid Speech Mini speech model (~240 MB) into
`ios/Models`, outside git, and the build bundles it for dictation. Without it, dictation uses Apple's model only.
