# 0008 · Hands transport: a paired TLS listener by default, SSH as an option

> Superseded in part by [0019](0019-drop-pi-env-compat.md): SSH (point 5) is no longer a transport.

**Status:** accepted (18 Oct 2026). Supersedes the transport part of 0005.

## Context

ADR 0005 assumed SSH from the phone. That works for servers, but for a personal agent it is the wrong default:
- macOS ships with Remote Login off.
- Ed25519 keys and `authorized_keys` are setup friction.
- SSH gives the phone nothing the daemon can't give it.

## Decision

`hands` gets its own listener, with code pairing.

1. **Discovery.** `hands pair` (and later `hands serve --listen`) listens on a random TCP port and announces itself over Bonjour as `_mycroft-hands._tcp`. It prints a QR code (`mycroft-hands://pair?host=…&port=…&code=…&fp=…`) and a short code, both valid for 2 minutes.
2. **Channel.** WebSocket over TLS 1.3. `hands` has a long-lived self-signed key and certificate. Each binary WebSocket message carries exactly one pi-env frame, as specified in hands/docs/protocol.md, so the operations are unchanged.
3. **Pairing.**
   - The phone connects. It checks the certificate fingerprint when it came from the QR code; when the code was typed, it trusts the certificate on first use.
   - Both sides send `pair` proofs: `HMAC-SHA256(code, role ‖ SHA-256(server certificate as the phone sees it) ‖ phone public key ‖ server nonce ‖ phone nonce)`. A relaying man in the middle presents its own certificate, so the proofs no longer match on the other side, and it cannot forge new ones without the code.
   - Five wrong proofs, or the expiry, invalidate the code.
   - On success, the phone stores the server certificate fingerprint and `hands` stores the phone's Ed25519 public key under a name.
4. **Reconnecting.** TLS with the pinned certificate, then `auth`: the server sends a nonce, the phone signs `"mycroft-auth" ‖ certificate fingerprint ‖ nonce` with its Ed25519 key, and the server checks it against the paired keys.
5. **SSH stays** as a second transport (`hands serve --stdio` over `ssh`) for servers that already have keys set up. Both transports carry the same frames.

## Consequences

- No SSH and no key setup on Macs: install `hands`, run `hands pair`, scan.
- `hands` now opens a listening port. It accepts nothing but the pairing and auth handshakes until a peer authenticates, and it can bind to the LAN or Tailscale interfaces only.
- Reaching a machine from outside its network still needs a route: Tailscale today, and later a relay mode (M5.5) where `hands` connects out to a rendezvous service and the traffic stays end-to-end encrypted with the paired keys.
- gRPC was rejected: it would add HTTP/2 and code generation on both ends to carry a protocol we already have.
