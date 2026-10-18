# Installing and pairing hands

This is the contract between the Mycroft iOS app and `hands`. It covers the one-line install served by the phone, the
listener `hands` runs afterwards, and how the phone authenticates to it. See also ADR 0008.

All hashes are SHA-256. `base64` is standard base64 with padding. `hex` is lowercase.

## 1. One-line install, served by the phone

When the user taps **Add machine**, the app:

1. Creates a one-time setup id `S`. It is 8 characters from `abcdefghjkmnpqrstuvwxyz23456789`, is valid for 10 minutes, and can complete pairing exactly once.
2. Starts an HTTPS server on a random port `P`, using a self-signed ECDSA P-256 certificate.
   - The certificate pin is `PIN = base64(sha256(SubjectPublicKeyInfo DER))`, which is curl's `--pinnedpubkey sha256//` format.
3. Copies this command to the clipboard (`IP` is the phone's Wi-Fi address):

   ```sh
   curl -fsSLk --pinnedpubkey sha256//PIN https://IP:P/S | sh
   ```

`-k` only skips CA verification. curl still enforces the pin, so the command cannot be served by anyone else.

### Phone endpoints (under `https://IP:P/S`)

| Method and path | Response |
|---|---|
| `GET /S` | `text/x-shellscript`: the install script, with `BASE`, `PIN` and the binaries' SHA-256 filled in |
| `GET /S/hands-<os>-<arch>` | the binary. `os`: `darwin` or `linux`. `arch`: `arm64` or `x86_64` on darwin, `aarch64` or `x86_64` on linux (`uname -m` names) |
| `GET /S/MycroftHands.zip` | `application/zip`: Mycroft Hands.app, the macOS desktop helper (see [§1.1](#11-the-desktop-helper-mycrofthandszip)). `404` when this build of the app has none |
| `POST /S/pair` | JSON pairing request (below). `200` with the phone's identity. `410` once `S` has been used or has expired. `400` on bad input |

Any other path, or an unknown or expired `S`, gets `404`.

### The install script

The template is `hands/scripts/phone-install.sh`. The app fills in `@BASE@`, `@PIN@`, `@SHA256_<os>_<arch>@` and
`@SHA256_desktop@`. The script:

1. Picks `hands-<os>-<arch>` from `uname -s` and `uname -m`.
2. Downloads it with the same curl flags (`-fsSLk --pinnedpubkey sha256//$PIN`) into a temp dir.
3. Verifies its SHA-256 with `shasum -a 256` or `sha256sum`, and aborts on a mismatch.
4. On macOS only, if `@SHA256_desktop@` was filled in with 64 lowercase hex digits, downloads `MycroftHands.zip` with
   the same curl flags and verifies it the same way:
   - a mismatch aborts the whole install, and nothing is installed;
   - a failed download (a `404`, say) prints one warning on stderr, and hands is installed without the helper;
   - a placeholder left as is (or filled with an empty string) skips this step silently.
5. Runs `"$TMP/hands" install --pair "$BASE" --pin "$PIN"`, plus `--desktop-zip "$TMP/MycroftHands.zip"` when step 4
   fetched it. That copies the binary, sets up the service, installs the helper and its LaunchAgent, opens the helper
   so macOS asks for its permissions, and pairs.
6. Prints one line saying the machine is paired. With the helper, `install` prints a second line asking the user to
   approve "Mycroft Hands" for Accessibility and Screen Recording, unless both are granted already.

The script must be POSIX `sh`, finish in seconds, and print nothing else unless something fails.

### 1.1 The desktop helper (`MycroftHands.zip`)

This is the contract for the iOS app; `hands` and the script above implement the other side.

- **Build.** `desktop/scripts/build.sh` produces `desktop/dist/MycroftHands.zip` (about 0.7 MB): `Mycroft Hands.app`,
  signed, zipped with `ditto -c -k --keepParent`, so the zip's top-level entry is `Mycroft Hands.app/`. The build
  prints the zip's SHA-256.
- **Bundle.** The app copies that file, byte for byte, into its resources as `hands-dist/MycroftHands.zip`, next to
  the `hands-<os>-<arch>` binaries. A missing file is a build warning, not an error, as with the binaries.
- **Serve.** `GET /S/MycroftHands.zip` answers `200` with `Content-Type: application/zip` and exactly those bytes, under
  the same rules as the binaries: only for the current, unexpired `S`, without using `S` up. Without the file in the
  bundle it answers `404`.
- **Fill.** In the script, the app replaces the exact text `@SHA256_desktop@` with the lowercase hex SHA-256 (64
  characters) of the same bytes it serves. Without the file in the bundle, it leaves the placeholder as is (or
  replaces it with an empty string); the script then installs hands without the helper and prints nothing about it.
  The placeholder is separate from the `@SHA256_<os>_<arch>@` ones, so a loop over the binaries' targets does not
  fill it.
- **Platforms.** The script fetches the zip only on macOS, for both architectures (the app is universal). Linux
  machines never request it.

`hands install --desktop-zip` then unpacks the app to `~/Applications/Mycroft Hands.app`, replacing an installed copy
only when `CFBundleShortVersionString` differs, after checking its bundle id and code signature. It writes and loads
the LaunchAgent `dev.mycroft.hands-desktop` (`hands-desktop serve` with `HANDS_STATE_DIR`), and runs
`open -n -g "~/Applications/Mycroft Hands.app" --args --request-permissions --wait 600` without waiting for it. A
failure in any of this is one warning on stderr, and pairing goes ahead without desktop control.

### `POST /S/pair`

`hands` sends this from `hands install --pair BASE --pin PIN` (or `hands pair --with BASE --pin PIN`) once its listener is running. It uses rustls with the same SPKI pin.

Request:

```json
{
  "name": "mac-mini",
  "os": "macos",
  "arch": "aarch64",
  "version": "0.2.0",
  "port": 50321,
  "certSha256": "<hex sha256 of the listener certificate DER>",
  "addresses": ["192.168.1.40", "100.101.102.103"],
  "hostname": "mac-mini.local"
}
```

Response `200`:

```json
{ "phoneName": "Vojta's iPhone", "publicKey": "<base64 of the phone's raw 32-byte Ed25519 public key>" }
```

`hands` then appends `{ name: phoneName, publicKey, pairedAt }` to `paired.json` in its state dir (mode 0600).

The phone stores the machine with these fields:
- `name`
- `hostname`
- `addresses`, plus the source address of the request
- `port`
- `certSha256`, pinned
- `os`, `arch` and `version`

Trust comes from the pinned TLS channel together with knowing `S`.

## 2. The listener

`hands supervise --listen`, which is what the installed service runs, serves WebSocket over TLS 1.3.

- **Port:** chosen at random on first start and kept in `listener.json` in the state dir. It is the same port that was sent when pairing.
- **Bind:** `0.0.0.0`, or `--bind ADDR`.
- **Certificate:** self-signed ECDSA P-256, generated once and kept as `listener-cert.pem` and `listener-key.pem` (0600). `certSha256` is the SHA-256 of its DER.
- **WebSocket:** upgrade on path `/v1`. Before authentication, all messages are text JSON.

### Handshake

1. The server sends `{ "type": "hello", "version": "0.2.0", "name": "mac-mini", "nonce": "<base64 of 32 random bytes>" }`.
2. The client sends `{ "type": "auth", "publicKey": "<base64 raw ed25519>", "signature": "<base64 64 bytes>" }`. The signature is Ed25519 over the UTF-8 string `mycroft-auth:<certSha256 hex>:<nonce base64>`.
3. The server answers one of:
   - `{ "type": "ready" }` if `publicKey` is in `paired.json` and the signature verifies;
   - `{ "type": "error", "code": "unauthorized" }`, followed by closing the connection.
   
   No other message is accepted before `ready`. The handshake must finish within 10 seconds.

### After `ready`

- Every binary message carries exactly one complete pi-env frame, including its 4-byte length prefix (see protocol.md), in both directions.
- The listener runs one `hands serve --token <random>` child per connection:
  - it strips the child's sync line;
  - it splits the child's stdout into frames;
  - it writes each incoming frame to the child's stdin.
- When the WebSocket closes, the child is killed. Supervised jobs keep running.
- Either side may send WebSocket pings. The listener closes connections that have been silent for 60 s; pi-env's own 5 s pings keep a healthy connection busy.

## 3. Discovery (optional)

The listener advertises `_mycroft-hands._tcp` on the local network with TXT `name`, `version` and `cert` (the first 16 hex digits of `certSha256`). The phone uses it to find a paired machine whose address changed. Pairing never depends on it.

## 4. Test vectors

These are exact and deterministic. `hands` checks them in `src/tls.rs` (`auth_test_vector`, `pin_test_vector`), and
OpenSSL reproduces them independently.

### `auth` signature

| | value |
|---|---|
| phone private key (Ed25519 seed, hex; RFC 8032 test 1) | `9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60` |
| phone public key (raw, hex) | `d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a` |
| `publicKey` (base64) | `11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=` |
| `certSha256` | `000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f` |
| nonce bytes | `0x20, 0x21, ..., 0x3f` (32 bytes) |
| `nonce` (base64, as in `hello`) | `ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=` |

The signed string, as UTF-8 bytes (one line, no trailing newline):

```text
mycroft-auth:000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f:ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=
```

Its Ed25519 signature, base64 (the `signature` field):

```text
qKa3C0FH/CS/urmfJt5xfB2h0Tsk4YQrtxDZg6nxzkTrv5ZBl2ILTqyAMZZr3eSg/o1LivawmAeBjzDQsUxPDg==
```

The same signature in hex:

```text
a8a6b70b4147fc24bfbab99f26de717c1da1d13b24e1842bb710d983a9f1ce44ebbf964197620b4eac8031966bdde4a0fe8d4b8af6b09807818f30d0b14c4f0e
```

The `auth` message:

```json
{ "type": "auth", "publicKey": "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo=", "signature": "qKa3C0FH/CS/urmfJt5xfB2h0Tsk4YQrtxDZg6nxzkTrv5ZBl2ILTqyAMZZr3eSg/o1LivawmAeBjzDQsUxPDg==" }
```

RFC 8032 Ed25519 is deterministic, so a signer that follows it reproduces these bytes. CryptoKit's
`Curve25519.Signing` signatures can be randomized and still be valid. An iOS test should therefore:
- check that the vector signature verifies under the vector public key;
- check that its own signature over the signed string verifies;
- not compare its own signature bytes with the vector.

### `PIN`

For the P-256 public key of private scalar 1 (the curve generator), the SubjectPublicKeyInfo DER (hex) is:

```text
3059301306072a8648ce3d020106082a8648ce3d030107034200046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5
```

This is what CryptoKit's `P256.Signing.PublicKey.derRepresentation` returns. Its pin, `base64(sha256(SPKI DER))`, is:

```text
XNJS+wzokyQ2+vjM0QQJgbie5K1rn+niorfnGqyyfNM=
```

## Notes from implementation

These record how `hands` 0.2.0 reads the parts the sections above leave open. The wire contract above is unchanged.

**Pairing request (`hands pair`, `hands install --pair`)**
- **Pin check.** `PIN` is compared with the SHA-256 of the leaf certificate's SubjectPublicKeyInfo. There is no CA, hostname or validity check. The TLS handshake signature is still verified against that certificate's key. The whole handshake, and with it the pin check, completes before any byte of the HTTP request is written, so a wrong pin sends nothing. `--pin` also accepts curl's `sha256//` prefix.
- **TLS versions.** Toward the phone, `hands` accepts TLS 1.2 and 1.3. The listener accepts TLS 1.3 only.
- **HTTP.** The request is HTTP/1.1 with `Content-Type: application/json` and `Connection: close`. The response body may be delimited by `Content-Length`, by chunked encoding, or by the end of the connection.
- **Error statuses.** `410`, `404` and `400` each produce their own message, and pairing then fails with exit status 1.
- **`name` and `hostname`.**
  - On macOS: `scutil --get LocalHostName` (e.g. `mac-mini`) and `<that>.local`.
  - Elsewhere: the first label of `gethostname()`, and `gethostname()` itself.
  - The listener's `hello.name` is the same `name`.
- **`addresses`.** The IPv4 addresses of interfaces that are up, excluding loopback and link-local (`169.254/16`). If the listener is bound to one address (`--bind`), it is that address only. IPv6 addresses are not sent.
- **`paired.json`.** A JSON array of `{ "name", "publicKey", "pairedAt" }`, with mode 0600. `pairedAt` is Unix time in milliseconds, like the job timestamps in jobs.md.
  - Pairing a key that is already present replaces its entry, so there is one entry per key.
  - Two phones with the same name are kept as separate entries.
  - `hands unpair <name>` removes every entry with that name, or the entry whose `publicKey` equals the argument.
  - The file is read at every `auth`, so changes apply to the next connection. Connections that are already open stay open.
- **Ensuring the listener runs.**
  - `hands pair` starts `hands supervise --listen --detached` if no listener holds `listener.lock`. It never touches services.
  - `hands install --pair` first waits up to 10 s for the service's listener.
  - If the service could not be started (a Mac with no GUI login, or no user systemd), or with `--no-service`, it falls back to a detached listener started from `~/.local/bin/hands`. That listener runs until the machine restarts, and the service's listener takes over at the next login. In that case `install` prints one warning line on stderr.
  - On Linux, with `--pair`, a failed `systemctl --user daemon-reload` or `enable --now` is not fatal for the same reason.
- **Output.** With `--pair`, `hands install` prints only `Paired with <phoneName>. Mycroft can use this <Mac|machine> now.` on stdout, and failures on stderr. This is the "one line" of §1 step 6: the script prints nothing of its own when it succeeds. With `--desktop-zip`, when it opened the helper to ask for its permissions, it prints one more line after it: `Approve "Mycroft Hands" for Accessibility and Screen Recording when macOS asks (or in System Settings > Privacy & Security), so Mycroft can use this Mac's apps.`

**Listener**
- **Process.** `supervise --listen` is the listener and the supervisor in one process.
  - It holds `listener.lock` and writes its pid there. When started by the service it waits for the lock; when started with `--detached` it exits if another listener holds the lock.
  - If another (on-demand) supervisor holds `supervisor.lock`, the listener serves anyway and takes the supervisor role when that supervisor exits.
  - `hands install` stops a running listener before (re)starting the service.
- **Port.** The port is chosen at random from 49152–65535 by whichever comes first, `hands pair` or the listener, and is stored as `{ "port": N }` in `listener.json` (0600). It never changes after that. If it is taken when the listener starts, the listener fails and the service retries. Moving to another port means deleting `listener.json` and pairing again.
- **Certificate.** Common name `Mycroft hands on <name>`, subject alternative name `hands`, and rcgen's default validity (1975 to 4096). The phone pins `certSha256` and should not evaluate the name or the dates.
- **Handshake.**
  - The upgrade path is matched without its query string. Any other path gets HTTP `404`.
  - WebSocket ping and pong control frames are allowed before `ready`.
  - Anything else that is not a valid, verifying `auth` gets `{ "type": "error", "code": "unauthorized" }` and a close frame with code 1008. This covers a binary message, another `type`, malformed JSON, a malformed key or signature, an unpaired key, and a bad signature.
  - The 10 s limit covers TCP accept to `ready`, TLS and the upgrade included. A watchdog shuts the socket at the deadline.
  - At most 32 connections may be in their handshake at once. Further ones are dropped at accept.
  - Before `ready`, a peer may send at most 64 KiB in total (the upgrade request and `auth`). Beyond that the connection is closed.
- **After `ready`.**
  - Text messages are ignored.
  - A binary message that is not exactly one frame closes the connection with code 1002. That is a message under 13 bytes, or one whose length prefix differs from the message length minus 4.
  - The largest accepted message is 16 MiB + 4 bytes.
  - "Silent" means no message of any kind, pings included, for 60 s. Such a connection is closed with code 1001.
  - If `serve` exits, the connection is closed with code 1000.
  - When the connection ends, `serve`'s stdin is closed, which makes it kill the commands it started and exit, as on a dropped SSH session. It is killed if it is still running after 3 s.
  - `serve` runs in the user's home directory, and its stderr goes to the supervisor log.
- **Discovery.** The instance name is `name`.
  - On macOS, registration goes through the system's mDNSResponder (`dns_sd`). On Linux, `hands` runs its own responder (`mdns-sd`).
  - It is skipped when the listener is bound to a loopback address. `HANDS_MDNS=0` turns it off and `HANDS_MDNS=1` forces it on.

**Install script**
- **Rosetta.** On Apple silicon, a shell running under Rosetta still gets `hands-darwin-arm64` (via `sysctl hw.optional.arm64`).
- **Architecture aliases.** On Linux, `uname -m` values `amd64` and `arm64` are accepted as aliases for `x86_64` and `aarch64`.
- **Structure.** All the work happens in one function called on the last line, so a script that is cut short in transit runs nothing.
- **stdin.** curl and `hands` get `/dev/null` on stdin, so neither can read the rest of the piped script.
