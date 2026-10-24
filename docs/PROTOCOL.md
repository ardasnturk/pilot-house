# Pilothouse Wire Protocol — version 1

This document specifies how the Pilothouse iOS app (the *client*) talks to the
Pilothouse Mac app (the *host*). The reference implementation is
`PilothouseKit/Sources/PilothouseKit/Protocol` and `…/Crypto`.

## 1. Layers

```
┌──────────────────────────────────────────────┐
│ JSON envelope  { v, id, re?, ts, type, payload } │  application protocol (§4)
├──────────────────────────────────────────────┤
│ Noise transport frames (ChaCha20-Poly1305)       │  secure channel (§3)
├──────────────────────────────────────────────┤
│ WebSocket binary messages                        │  framing
├──────────────────────────────────────────────┤
│ TCP  (LAN, or the Tailscale tunnel)              │
└──────────────────────────────────────────────┘
```

* **Port:** 47823 by default; if taken, the host binds the next free port of
  47823–47842 and publishes the actual port in the QR code and over Bonjour.
* **Discovery:** Bonjour service type `_pilothouse._tcp`, TXT record
  `id=<mac fingerprint>`, `v=1`.
* **Client connection order:** last successful address → Bonjour → LAN IPs →
  Tailscale IPs → MagicDNS name. Failed rounds back off exponentially
  (1, 2, 4 … 30 s, jittered); the app skips the wait when it returns to the
  foreground or the network changes.
* Only WebSocket **binary** messages are used. The first byte is the frame type.

| Byte | Frame | Direction |
|---|---|---|
| `0x01` | Noise IK message 1 | client → host |
| `0x02` | Noise IK message 2 | host → client |
| `0x03` | Encrypted transport frame | both |

## 2. Pairing (QR code)

The host shows a QR code for

```
pilothouse://pair?d=<base64url(JSON)>
```

```json
{
  "v": 1,
  "name": "Arda's MacBook Pro",
  "pk": "<base64url, 32-byte X25519 public key of the Mac>",
  "lan": ["192.168.1.20"],
  "ts": ["100.101.102.103"],
  "dns": "macbook.tail1234.ts.net",
  "port": 47823,
  "token": "<base64url, 32 random bytes>",
  "exp": 1792813792
}
```

* `token` is single-use and expires 5 minutes after creation (`exp`, Unix seconds).
* The client connects to the listed addresses and performs the handshake with
  `mode: "pair"` and the token. On success both sides store each other's
  public key; all later connections use `mode: "connect"`.
* The URL scheme `pilothouse` is registered by the iOS app, so the system
  Camera can open the link too. Base64url is unpadded (RFC 4648 §5).

## 3. Secure channel

### 3.1 Handshake — `Noise_IK_25519_ChaChaPoly_SHA256`

Implemented per the Noise Protocol Framework rev. 34 and verified against the
cacophony test vector (`NoiseTests`).

```
IK:
  <- s                    (host's static key, known from the QR code)
  ...
  -> e, es, s, ss         frame 0x01 ‖ message 1
  <- e, ee, se            frame 0x02 ‖ message 2
```

* Prologue: ASCII `Pilothouse handshake v1`.
* **Message 1 payload** (encrypted; JSON):

  ```json
  { "protocolVersion": 1, "mode": "pair" | "connect", "pairingToken": "…",
    "deviceName": "Arda's iPhone", "platform": "iOS", "appVersion": "1.0 (1)",
    "timestamp": "2026-10-24T03:47:33.439Z" }
  ```

* **Message 2 payload** (encrypted; JSON):

  ```json
  { "protocolVersion": 1, "accepted": true, "macName": "…", "macId": "…",
    "serverTime": "2026-10-24T03:47:33.512Z",
    "error": { "code": "pairingTokenInvalid", "message": "…" } }
  ```

  A rejected handshake still sends message 2 (with `accepted: false` and
  `error`) so the phone can show an authenticated reason; then the host closes.
* The host rejects message 1 when the protocol version differs
  (`protocolMismatch`) or `timestamp` is more than 300 s from its clock
  (`clockSkew`); the client applies the same skew check to `serverTime`.
* If message 1 cannot be decrypted (the client pinned a different host key —
  e.g. a man-in-the-middle answered), the host closes without replying.

### 3.2 Transport frames

```
0x03 ‖ counter (8 bytes, big-endian) ‖ ChaCha20-Poly1305(ciphertext ‖ 16-byte tag)
```

* Keys come from Noise `Split()`; one key per direction.
* `counter` starts at 0 per direction and must be **exactly** the next
  expected value; any other value closes the connection (replay, reordering
  and drops are all detected).
* Nonce: 4 zero bytes ‖ counter as little-endian 64-bit (Noise convention).
* Associated data: the 9 header bytes (`0x03 ‖ counter`).
* Maximum message size: 16 MiB.

## 4. Application messages

Every plaintext is one UTF-8 JSON object:

```json
{ "v": 1, "id": "6C1E…", "re": "A93F…", "ts": "2026-10-24T03:47:33.439Z",
  "type": "sendMessage", "payload": { … } }
```

| Field | Meaning |
|---|---|
| `v` | Protocol version (`1`). A different value yields `error{code: "protocolMismatch"}`. |
| `id` | Unique message ID (UUID). |
| `re` | Host → client only: the `id` of the request this answers. Absent on pushes. |
| `ts` | Sender clock, ISO 8601 with milliseconds. The host drops requests more than 10 min off its clock (`clockSkew`). |
| `type` | Message type (below). Unknown types yield `error{code: "unknownMessage"}`. |
| `payload` | Type-specific object (`{}` when empty). |

Dates are ISO 8601 strings with fractional seconds. Unknown JSON fields must be
ignored by receivers. Every request gets exactly one response with `re` set:
the documented result, `ok`, or `error`.

### 4.1 Client → host

| `type` | `payload` | Response |
|---|---|---|
| `hello` | `{ protocolVersion, appVersion, deviceName, platform }` — **must be first** | `helloAck` |
| `macStatus` | `{}` | `macStatus` |
| `listDirectory` | `{ path?: "~/Developer" \| "/Users/a/x", showHidden: false }` | `directoryListing` |
| `createDirectory` | `{ parent, name }` — `name` is one visible path component; capability `createDirectory` | `directoryListing` of `parent` |
| `listSessions` | `{}` | `sessionList` |
| `startSession` | `{ cwd, model?, permissionMode?, firstMessage?, agent? }` — `agent` ∈ `claude` (default) · `codex` · `gemini`; capability `agents` | `sessionStarted` |
| `resumeSession` | `{ sessionId }` | `sessionStarted` |
| `sendMessage` | `{ sessionId, text, attachments?: [{ mediaType, data (base64), filename? }] }` | `ok` |
| `interrupt` | `{ sessionId }` | `ok` |
| `closeSession` | `{ sessionId }` | `ok` |
| `deleteSession` | `{ sessionId }` | `ok` |
| `subscribe` | `{ sessionId, fromSeq }` | `ok`, then `event` pushes |
| `unsubscribe` | `{ sessionId }` | `ok` |
| `permissionResponse` | `{ requestId, allow, remember? }` | `ok` |

`permissionMode` ∈ `default` · `acceptEdits` · `plan` · `bypassPermissions`
(the last one only if the Mac user enabled it; otherwise `modeNotAllowed`).
Attachments are images (`image/jpeg|png|gif|webp`, ≤ 5 MB each).

Messages added after 1.0 are announced in `helloAck.capabilities` (missing on
older Macs). A client only sends them when the Mac lists the capability, so
`version` stays 1. Capabilities so far (all 1.1): `createDirectory`,
`agents` (`startSession.agent`, `Session.agent`, `macStatus.agents`) and
`threads` (`event.thread`).

### 4.2 Host → client

| `type` | `payload` |
|---|---|
| `helloAck` | `{ protocolVersion, macName, macId, serverVersion, pendingPermissions: [PermissionRequest], capabilities?: [String] }` |
| `ok` | `{}` |
| `macStatus` | `{ macName, sleepPrevented, lidClosedModeEnabled, claude: { installed, path?, version? }, tailscale: { installed, running, backendState?, ipv4?, ipv6?, magicDNSName?, tailnetName?, magicDNSEnabled }, addresses: [{ host, kind }], port, activeSessionCount, bypassPermissionsAllowed, defaultModel?, agents?: [{ kind, installed, path?, version?, loggedIn?, models, delegationEnabled }] }` |
| `directoryListing` | `{ path, homePath, parentPath?, isGitRepository, truncated, entries: [{ name, path, isDirectory, isHidden, isSymbolicLink, isGitRepository, size?, modifiedAt? }] }` |
| `sessionList` | `{ sessions: [Session] }` |
| `sessionStarted` / `sessionUpdated` | `{ session: Session }` |
| `sessionDeleted` | `{ sessionId }` |
| `sessionEnded` | `{ sessionId, reason: closedByUser \| deleted \| processFailed \| macShuttingDown, message? }` |
| `event` | `{ sessionId, seq, ts, ephemeral?, thread?, payload: SessionEvent }` — `thread` is the tool-use ID of the sub-agent (`Task` or `delegate_to_agent`) the event belongs to |
| `permissionRequest` | `{ requestId, sessionId, tool, input, cwd, createdAt, expiresAt, rememberKey }` |
| `permissionResolved` | `{ requestId, sessionId, outcome: allowed \| allowedForSession \| denied \| timedOut \| cancelled }` |
| `error` | `{ code, message }` |

`Session`:

```json
{ "id": "1b6e…", "cwd": "/Users/a/Developer/app", "title": "Fix the flaky test",
  "lastMessagePreview": "…", "createdAt": "…", "updatedAt": "…", "model": "sonnet",
  "permissionMode": "default", "state": "starting|running|awaitingPermission|idle|closed",
  "lastSeq": 42, "slashCommands": ["review", "compact"], "agent": "codex" }
```

The session `id` is also the Claude Code session ID (`--session-id` /
`--resume`).

Pushes without `re` (`sessionStarted`, `sessionUpdated`, `sessionDeleted`,
`sessionEnded`, `permissionRequest`, `permissionResolved`, `macStatus`) are
broadcast to every connected client after its `hello`.

### 4.3 Error codes

`protocolMismatch`, `invalidRequest`, `unknownMessage`, `notFound`,
`pathOutsideHome`, `privacyPermissionRequired` (macOS privacy settings block a
folder; `message` says which switch to turn on), `notADirectory`,
`alreadyExists`, `invalidName`, `agentNotInstalled`,
`claudeNotInstalled`, `sessionClosed`, `modeNotAllowed`, `unauthorized`,
`deviceRevoked`, `pairingTokenInvalid`, `clockSkew`, `timeout`, `internal`.
Codes are open-ended strings; clients must handle unknown codes generically.

## 5. Session events

`event.payload` is a normalised form of Claude Code's `stream-json` output: a
flat object with a `type` discriminator.

| `type` | Fields | Persisted |
|---|---|---|
| `userMessage` | `text, attachmentCount` | ✓ |
| `assistantTextDelta` | `blockId, text, replace` | ephemeral |
| `assistantMessage` | `blockId, text` | ✓ |
| `thinking` | `blockId, text, isComplete` | only when `isComplete` |
| `toolUse` | `toolUseId, name, input` | ✓ |
| `toolResult` | `toolUseId, output, isError` | ✓ |
| `fileEdit` | `toolUseId, path, kind: created\|modified, diff` (unified diff) | ✓ |
| `result` | `isError, subtype, durationMs, numTurns?, costUSD?, usage?{inputTokens, outputTokens, cacheReadInputTokens, cacheCreationInputTokens}, text?` | ✓ |
| `systemNotice` | `kind, level: info\|warning\|error, text` | ✓ |
| `sessionInfo` | `claudeSessionId, model?, permissionMode?, cwd?, claudeVersion?, slashCommands` | ✓ |
| `permissionDecision` | `requestId, toolName, summary, outcome` | ✓ |

Unknown event types must be shown as a generic notice, not dropped silently.

### 5.1 Sequencing and catch-up

* Persisted events get a per-session `seq` starting at 1, strictly increasing,
  and are appended to `~/Library/Application Support/Pilothouse/sessions/<id>.jsonl`.
* Ephemeral events (`assistantTextDelta`, incomplete `thinking`) are only
  broadcast live. They carry the `seq` of the last persisted event and
  `ephemeral: true`; they never advance the client's cursor.
* `subscribe{sessionId, fromSeq}` first replays every persisted event with
  `seq ≥ fromSeq`, then — if a text block is still streaming — one
  `assistantTextDelta` with `replace: true` holding the text so far, then live
  events. A client keeps `lastSeq` per session and re-subscribes with
  `lastSeq + 1` after every reconnect; Claude keeps working on the Mac while
  the phone is away.
* `blockId` (`<API message id>:<content block index>`) ties deltas to the final
  `assistantMessage`, which replaces the streamed text.

### 5.2 `toolUse.input` by tool (informative)

The host forwards Claude's tool input unchanged, except that strings longer
than 64 KiB are truncated with a marker. Commonly used fields:

| Tool | Fields the iOS app renders |
|---|---|
| `Read` | `file_path`, `offset?`, `limit?` |
| `Edit` / `MultiEdit` | `file_path`, `old_string`, `new_string` (diff comes as `fileEdit`) |
| `Write` | `file_path`, `content` |
| `Bash` | `command`, `description?` |
| `Grep` / `Glob` | `pattern`, `path?` |
| `WebFetch` / `WebSearch` | `url` / `query` |
| `TodoWrite` | `todos: [{ content, status: pending\|in_progress\|completed, activeForm }]` |

## 6. Versioning

* `v` in the envelope and `protocolVersion` in the handshake must equal `1`.
* Backwards-compatible additions (new optional fields, new event types, new
  error codes) do not bump the version. Anything else does.
* A version mismatch is reported in the handshake (`protocolMismatch`) with a
  message asking the user to update both apps.
