# hands

The executing half of Mycroft: a small daemon for **macOS and Linux** that you install on your servers and Macs. The brain on the iPhone connects over SSH and uses it to work with files, run commands and jobs, and (on macOS) drive the desktop.

> Status: design. Implementation starts in milestone M5. See [ADR 0005](../docs/decisions/0005-hands-daemon.md).

## Planned commands

```sh
hands install            # install the binary, the supervisor service and (macOS) the desktop agent
hands pair               # print a QR code / pairing string with this host's key and address
hands serve --stdio      # what the phone runs over SSH; pi-env-compatible framed protocol
hands jobs               # list supervised jobs
hands doctor             # check SSH, supervisor, Accessibility permission
```

## What it adds over pi-env

| | pi-env | hands |
|---|---|---|
| Files, exec, PTY, `listFiles` | ✓ | ✓ (same wire semantics) |
| Commands survive the client disconnecting | ✗ (killed after ~30 s idle) | ✓ supervised jobs keyed by tool-call id, reattachable output |
| Desktop control | ✗ | macOS: `ui.observe` (AX tree with element refs), `ui.act` (press, type, scroll, focus), screenshots |
| Install | auto-uploaded per connection | `hands install` once; auto-update by SHA-256 like pi-env |

## Security

- SSH only. No listening ports. The phone pins the host key from pairing.
- No model credentials ever reach `hands`. Jev and the LLMs are called from the phone.
- On macOS, Accessibility permission is granted to the desktop agent only. The SSH-side process talks to it over a user-only Unix socket.
