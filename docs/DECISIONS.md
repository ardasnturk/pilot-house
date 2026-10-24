# Architecture & Design Decisions

Every decision the master prompt left open is recorded here with a short
rationale, in the order it was made. Entries are never deleted; a superseded
decision is marked as such and points to its replacement.

Format: `D-NNN — Title` · status · rationale.

---

## Phase 0 — Research

### D-001 — Verified Claude Code CLI surface (v2.1.310, 2026-10)
**Status:** accepted

Before writing code the current CLI (`claude --help`, v2.1.310) and the
official docs (code.claude.com/docs: `cli-reference`, `headless`,
`permission-modes`, `env-vars`, `mcp`, Agent SDK reference) were read, and
every flag was exercised against the real binary. Findings:

| Prompt assumption | Reality | What Pilothouse does |
|---|---|---|
| `-p --input-format stream-json --output-format stream-json --verbose --include-partial-messages` | All flags exist unchanged. | Used verbatim. |
| `--resume <sessionId>` | Exists; resumes by ID (searches all projects since v2.1.223). Verified that context survives an interrupted turn. | Used for "Continue" and after an interrupt. |
| `--permission-mode default|acceptEdits|plan|bypassPermissions` | `default` is still the config value. The CLI now *displays* it as "Manual" and accepts `manual` as an alias. New modes `auto` and `dontAsk` exist. | Send `default`; UI calls it "Ask every time". `auto`/`dontAsk` are not exposed in v1 (see D-006). |
| `--permission-prompt-tool` | Documented: "an MCP tool to handle permission prompts in non-interactive mode", full name `mcp__<server>__<tool>`. | Used (D-004). |
| `--model X` | Accepts aliases (`fable`, `opus`, `sonnet`, `haiku`) or full IDs. | Model picker offers aliases + free text. |
| — | `--session-id <uuid>` lets the caller choose the session ID up front. | New sessions are started with a pre-generated UUID so the event log can be created before `system/init` arrives; the ID from `system/init` is still authoritative. |

### D-002 — Interrupt = SIGINT, then transparent `--resume`
**Status:** accepted

The docs say: "To end the turn instead [of SIGTERM], send SIGINT". Measured
behaviour with `--input-format stream-json` on v2.1.310:

1. SIGINT during a streaming turn ends the turn: the CLI emits a synthetic
   user message `[Request interrupted by user]` and a `result` with
   `subtype: "error_during_execution"`.
2. **The process then exits** (also when SIGINT arrives while idle).
3. `claude -p --resume <id>` restarts with the full conversation context
   (verified by asking about the interrupted turn's topic).

Therefore "Stop" sends SIGINT to the child's **process group** (terminal
Ctrl-C semantics, so a running Bash tool child is interrupted too), marks the
session idle, and the next `sendMessage` lazily respawns the CLI with
`--resume`. The SDK's stdin control protocol (`control_request` /
`interrupt`) is not used: its wire format is not documented for CLI users
(prompt rule: no undocumented internal protocols).

### D-003 — Stop = SIGTERM → 5 s → SIGKILL
**Status:** accepted

Matches the prompt and the docs (SIGTERM exits 143 and kills running Bash
process trees; `SessionEnd` hooks run). Sent to the process group.

### D-004 — Permission prompts via a localhost **HTTP** MCP server inside the Mac app
**Status:** accepted

Each session's CLI is launched with

```
--mcp-config '{"mcpServers":{"pilothouse":{"type":"http","url":"http://127.0.0.1:<port>/mcp","headers":{"Authorization":"Bearer <per-session secret>"},"timeout":660000}}}'
--permission-prompt-tool mcp__pilothouse__approve_permission
```

Verified against the real CLI with a throwaway server:

* Handshake: optional `server/discover` probe (we answer JSON-RPC
  `-32601`), then `initialize`, `notifications/initialized`, an SSE `GET`
  (we answer `405`, allowed by the Streamable-HTTP spec), `tools/list`.
* Call arguments: `{"tool_name": "...", "input": {...}, "tool_use_id": "..."}`.
* Result: a `text` content block whose text is the JSON
  `{"behavior":"allow","updatedInput":{...}}` or
  `{"behavior":"deny","message":"..."}` (the documented `PermissionResult`).
* Only calls that actually need approval reach the tool (read-only Bash such as
  `cat` was auto-allowed).

Why HTTP and not stdio: no extra helper binary, no IPC hop, and the
per-session bearer token tells us which session is asking.

**Timeout:** HTTP MCP requests time out after 60 s by default and network
servers have a 5 min idle timeout (`MCP_TOOL_TIMEOUT` /
`CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT` docs). The per-server `"timeout": 660000`
(11 min) raises both, so our own 10-minute deny-on-timeout always wins.

`--strict-mcp-config` is **not** passed: users keep their own MCP servers.

### D-005 — Session state lives in the Mac app; the CLI process is disposable
**Status:** accepted

A Pilothouse session = metadata + an append-only event log + (optionally) a
running CLI process. The process is spawned on demand and may exit at any time
(interrupt, crash, Mac app restart); the next message respawns it with
`--resume`. This makes "continue later", crash recovery and interrupt the same
code path.

### D-006 — Permission modes offered in v1
**Status:** accepted

`default` ("Ask every time"), `acceptEdits`, `plan`. `bypassPermissions` only
after enabling it in Mac settings, shown with a red warning (prompt §4.4).
`auto` (classifier) and `dontAsk` are newer CLI modes; they are left out of v1
to keep the review surface small and are listed in `ROADMAP.md`.

---

## Phase 0 — Tooling & repository

### D-010 — Xcode project generated with XcodeGen (`project.yml`)
**Status:** accepted

A hand-maintained `.pbxproj` is merge-hostile. `project.yml` is the source of
truth; `scripts/bootstrap.sh` runs `xcodegen generate`. XcodeGen is a
build-time tool only — nothing third-party ships in the apps. The generated
`Pilothouse.xcodeproj` is git-ignored so the YAML stays authoritative.

### D-011 — Swift 6 language mode, tools-version 6.0
**Status:** accepted

Strict concurrency is on everywhere (`swiftLanguageModes: [.v6]` in the
package, `SWIFT_VERSION = 6.0` + `SWIFT_STRICT_CONCURRENCY = complete` in
Xcode). The package manifest uses `swift-tools-version: 6.0` so it builds with
both the current Xcode toolchain and the Linux CI toolchain (6.1.3).

### D-012 — Platform-neutral core, thin Apple shells
**Status:** accepted

Everything that is not UI, Keychain, IOKit or Network.framework lives in the
`PilothouseKit` package and compiles on Linux too: protocol, crypto
handshake, framing, stream-json normaliser, process supervision, event log,
path sandbox, MCP JSON-RPC handler, session manager. This lets the core be
unit-tested with `swift test` on any machine (including headless CI) and keeps
the app targets small.

### D-013 — CryptoKit on Apple, `swift-crypto` only on Linux
**Status:** accepted

The prompt forbids third-party dependencies. Apple's `swift-crypto` exposes
the same API as CryptoKit and is only needed where CryptoKit does not exist.
`Package.swift` adds it under `#if os(Linux)`, so Apple builds have **zero**
package dependencies. Code imports `CryptoKit` when available, `Crypto`
otherwise.

### D-014 — Swift Testing for unit tests, XCTest for UI tests
**Status:** accepted

Swift Testing (`import Testing`) is the current Apple recommendation and runs
on Linux. XCUITest still requires XCTest.

### D-015 — Documentation language
**Status:** accepted

Code, comments and `docs/` are in English (open-source convention); the
README exists in English and Turkish (`README.tr.md`) as required.

---

## Phase 1 — PilothouseKit

### D-020 — Keychain flavour per platform
**Status:** accepted

iOS: data-protection keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
not synchronisable. macOS: the login (file-based) keychain. The macOS
data-protection keychain requires an App ID entitlement, i.e. a provisioning
profile even for Developer ID builds; the login keychain needs none and still
binds the item to the app's code signature.

### D-021 — Noise IK instead of a home-grown handshake
**Status:** accepted

The prompt asks for "X25519 + HKDF + ChaChaPoly, MITM-proof thanks to the
Mac key in the QR code, mutual authentication afterwards". Noise
`IK_25519_ChaChaPoly_SHA256` is exactly that pattern, is formally analysed and
has public test vectors. It is ~250 lines on top of CryptoKit, so no
dependency is needed. Pairing and reconnecting use the same handshake; the
mode and the one-time token travel encrypted in message 1.

### D-022 — No TLS on the WebSocket
**Status:** accepted

TLS would need certificates for LAN IPs and Tailscale names that no public CA
issues, i.e. self-signed certificates plus pinning — which is what the Noise
layer already provides with less machinery. WebSocket is kept only for
message framing and NAT/proxy friendliness.

### D-023 — Ephemeral streaming deltas
**Status:** accepted

Text and thinking deltas are not persisted and carry no new sequence number;
the complete block follows as `assistantMessage`. Persisting every token would
make logs ~50× larger for no benefit. Late subscribers get one `replace`
delta with the text streamed so far (PROTOCOL.md §5.1).

### D-024 — Extra target `PilothouseHost` in the package
**Status:** accepted

The prompt's tree lists `Protocol/Crypto/Transport/Models` under
`PilothouseKit`. Mac-only *logic* (process supervision, normaliser, event log,
file sandbox, permission broker, MCP endpoint) goes into a second library in
the same package so it is unit-testable without an app host and never ships in
the iOS binary.

### D-025 — Demo mode = real protocol over an in-memory transport
**Status:** accepted

`DemoHostService` implements the same `HostService` protocol as the Mac and is
reached through `ServerEndpoint` + the real Noise channel over
`InMemoryTransport`. Demo mode, App Review and the UI tests therefore exercise
the production client stack end to end. Demo content is localised (EN/TR/DE)
for App Store screenshots.

### D-026 — Additional protocol messages beyond the prompt's list
**Status:** accepted

Added because the UI cannot work without them: `ok` (acknowledges commands),
`deleteSession`, `unsubscribe`, `sessionUpdated`, `sessionDeleted`,
`permissionResolved` (dismisses the card on other devices), the
`userMessage`, `sessionInfo` and `permissionDecision` events, and an optional
`re` field in the envelope for request/response correlation.

### D-027 — Sequential request handling per connection
**Status:** accepted

The host processes one connection's requests in order (all host operations
return quickly; long work such as a Claude turn runs in the background). This
keeps "send message A, then B" ordered without extra sequencing.

### D-028 — Linux CI toolchain
**Status:** accepted

The package is validated with Swift 6.1.3 on Linux (`swift test`) in
addition to Xcode. Network.framework, Security and IOKit code is behind
`#if canImport(...)` and is compiled only by Xcode.
