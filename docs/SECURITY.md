# Remote Code Security Model

Remote Code lets a phone drive a program (Claude Code) that can edit files and
run commands on a Mac. A compromised link is therefore equivalent to a remote
shell. This document states what we protect, how, and what is out of scope.

To report a vulnerability, open a GitHub security advisory on the repository
(Security → Report a vulnerability) instead of a public issue.

## 1. Assets and trust boundaries

| Asset | Where it lives |
|---|---|
| The Mac user's files and shell | The Mac; reachable only through the Claude CLI that Remote Code starts |
| Claude / Anthropic credentials | Managed by the official `claude` CLI. **Remote Code never reads, stores or transmits them.** |
| Optional Anthropic API key | macOS Keychain, only if the user opts into API-key mode; passed to the child process as `ANTHROPIC_API_KEY` and nowhere else |
| Mac identity private key | macOS login keychain (`Pilothouse identity key`), never leaves the Mac |
| Phone identity private key | iOS Keychain, `AfterFirstUnlockThisDeviceOnly`, not synced, not in backups |
| Session transcripts | `~/Library/Application Support/Pilothouse/sessions/*.jsonl` (mode 0600), pruned after 30 days; a cache on the phone (SwiftData, iOS data protection) |

Remote Code **never connects to Anthropic** and has **no telemetry**. The only
network traffic it creates is between your own devices.

## 2. Threats and mitigations

| Threat | Mitigation |
|---|---|
| Eavesdropping on the LAN / café Wi-Fi | All application data is end-to-end encrypted with ChaCha20-Poly1305 after a Noise IK handshake. WebSocket framing is plain; there is nothing useful in it. |
| Man-in-the-middle during pairing | The QR code carries the Mac's static public key. The phone uses it as the Noise IK pre-message, so only the holder of the matching private key can decrypt message 1 and produce message 2. An attacker on the network cannot learn or replace the key without physical access to the Mac screen. |
| Man-in-the-middle later | Both static keys are pinned after pairing; every connection is mutually authenticated (`es`, `ss`, `se` DH terms). |
| Someone on the LAN pairs a device | Pairing needs the one-time token shown in the QR code: 32 random bytes, valid for 5 minutes, single use, compared in constant time. The pairing window must be opened by the user on the Mac. |
| Stolen / lost phone | Revoke it in the Mac menu (Paired devices → Revoke). The key is deleted from the allow list and live connections from that device are dropped immediately. |
| Replay of captured traffic | Fresh ephemeral keys per connection make old frames undecryptable. Within a connection every frame has a strictly sequential 64-bit counter bound as AEAD associated data; any replayed, dropped or reordered frame closes the connection. Messages also carry a timestamp: the handshake requires clocks within 5 minutes and requests more than 10 minutes off are refused. |
| Phone asks for files outside the home folder | `listDirectory` normalises the path (`..` removal, symlink resolution via `resolvingSymlinksInPath`) and refuses anything outside the user's home folder. `startSession` applies the same rule to the working directory. |
| A local process abuses the permission endpoint | The MCP permission server listens on `127.0.0.1` only, requires a random per-session bearer token (32 bytes, constant-time compare), rejects requests carrying an `Origin` header (DNS-rebinding defence) and checks the `Host` header. A local process could at most *ask* for a permission — it cannot answer one. |
| Claude runs something dangerous | Claude Code's own permission system stays in charge. In the default mode every action that needs approval is forwarded to the phone and must be accepted explicitly; unanswered requests are **denied** after 10 minutes. `bypassPermissions` must be enabled in the Mac settings first and is shown in red. |
| Malicious QR code | The phone only connects to the addresses inside it and only completes the handshake with the key inside it; it cannot be tricked into talking to another Mac than the one whose key it scanned. |
| Privileged helper abuse (lid-closed mode) | The helper is installed via `SMAppService.daemon`, accepts XPC connections only from code signed by team `5JMD3VSD7N` with the app's bundle identifier, and exposes exactly one operation: set `disablesleep` to 0 or 1. It never runs any other command. |

## 3. Cryptographic details

* Handshake: `Noise_IK_25519_ChaChaPoly_SHA256` (X25519, HKDF-HMAC-SHA256,
  ChaCha20-Poly1305), CryptoKit primitives, validated against the cacophony
  test vectors.
* Prologue `Remote Code handshake v1` binds the protocol version.
* Transport keys: Noise `Split()`; nonce = counter; no re-keying (a connection
  would need 2⁶⁴ frames).
* Identifiers shown in the UI: `base64url(SHA-256(publicKey)[0..16])`, and a
  12-character verification code derived from the same hash.

## 4. Out of scope

* A compromised Mac or phone (malware with the user's privileges).
* Denial of service by someone on the same network (they can always drop packets).
* Claude Code's own security properties and Anthropic's services.
* Tailscale's security; Remote Code treats the tailnet like any other network
  and still encrypts end-to-end.

## 5. Local data hygiene

* Event logs are written with POSIX mode `0600` inside a `0700` directory and
  deleted after the retention period (default 30 days, configurable).
* Tool outputs larger than 64 KiB are truncated before they are stored or sent.
* Logs (`os.Logger`) never contain keys, tokens or message contents.
