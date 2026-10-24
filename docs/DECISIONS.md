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
**Status:** amended by D-036

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

---

## Phase 2 — Mac host and menu bar app

### D-030 — `posix_spawn` with a process group and a `/bin/sh` trampoline
**Status:** accepted

Foundation's `Process` cannot put the child into its own process group, which
is needed to deliver Ctrl-C-like SIGINT/SIGTERM to the CLI *and* the tools it
runs. `ChildProcess` uses `posix_spawn` with `POSIX_SPAWN_SETPGROUP`, default
signal dispositions, an empty signal mask and (on Darwin)
`POSIX_SPAWN_CLOEXEC_DEFAULT`. The working directory is set by
`/bin/sh -c 'cd -- "$1" || exit 126; shift; exec "$@"'` because
`posix_spawn_file_actions_addchdir(_np)` availability differs between SDKs and
glibc; `exec` keeps the PID, so signals still reach the CLI.

### D-031 — Permission MCP server on BSD sockets
**Status:** accepted

The loopback HTTP server for `--permission-prompt-tool` uses plain sockets and
one thread per connection instead of Network.framework. It only serves the
local CLI processes, blocking a thread while a permission waits is harmless, and
it runs unchanged on Linux — so the complete permission round trip (CLI →
curl/HTTP → broker → phone → answer) is covered by automated tests.

### D-032 — FakeClaude is a POSIX shell script
**Status:** accepted

The prompt asks for a fake `claude` for process tests. A `/bin/sh` script with
`curl` needs nothing that is not on every Mac and Linux CI image (no Python).
It emits stream-json shaped like the captured fixtures, calls the real MCP
endpoint for permissions and traps SIGINT like the real CLI.

### D-033 — Environment from the login shell
**Status:** accepted

GUI apps start with launchd's minimal `PATH`. Pilothouse runs
`$SHELL -ilc` (then `-lc`) printing `env -0` between markers, with a 10 s
timeout and a bounded read, so slow or chatty shell configs (prompts, plugin
daemons) cannot hang it. Falls back to the app environment plus the usual
tool directories.

### D-034 — Sign-in state from `claude auth status`
**Status:** accepted

The CLI (v2.1.310) prints `{"loggedIn": …}`. Pilothouse reads only that flag to
show "not signed in" hints; it never reads credential files. Sign-in itself is
always done by the user in Terminal (prompt §4.4).

### D-035 — The helper reverts `disablesleep` on disconnect
**Status:** accepted

The privileged helper remembers which XPC connection enabled
`disablesleep` and resets it to 0 when that connection is invalidated, so a
crash or force-quit of the app cannot leave the Mac permanently sleepless.
The app additionally pauses the mode on battery (polled every 20 s; default on).

### D-036 — Commit the generated Xcode project
**Status:** accepted (amends D-010)

`project.yml` stays the source of truth, but the generated
`Pilothouse.xcodeproj` is committed so contributors can open the repo in Xcode
without installing XcodeGen. CI/`scripts/bootstrap.sh` regenerate it.

### D-037 — Requested vs. reported model
**Status:** accepted

The model the user picked (alias such as `sonnet`) is stored separately from
the model the CLI reports in `system/init` (full ID). Restarts pass the
requested value to `--model`, so aliases keep tracking the latest model.

### D-038 — Granularity of "always allow in this session"
**Status:** accepted

Remembered per tool name, except `Bash`, which is remembered per program
(first word of the command, e.g. `Bash(npm)`), close to Claude Code's own
prefix rules. Rules live in the session record (they survive CLI restarts) and
are shown to the user on the permission card.

### D-039 — Menu bar UI
**Status:** accepted

`MenuBarExtra` with `.window` style (rich content: addresses, sessions, devices,
toggles) plus separate windows for pairing, Claude setup and Tailscale, and a
standard Settings scene. The controller is owned by the app delegate so the
server starts at login even if the menu is never opened.

### D-040 — Visual identity
**Status:** accepted

Pilothouse = a ship's wheelhouse; the icon is a helm on a deep-teal gradient
with a turquoise hub, generated by `scripts/generate-icons.py`. Accent colour
`#0E808C` / dark `#48CAD0`. No Anthropic or Claude marks, colours or logos are
used (prompt §6.1).

---

## Phase 3 — iOS app

### D-050 — Markdown without a dependency
**Status:** accepted

`AttributedString(markdown:)` renders inline syntax only. A ~200-line block
parser (`MarkdownBlock`, in PilothouseKit, unit-tested) splits replies into
headings, paragraphs, lists (incl. task lists), quotes, tables, rules and
fenced code (an unterminated fence while streaming is still shown as code);
each block's inline text goes through `AttributedString`. No third-party
Markdown package is needed (prompt §2).

### D-051 — One active Mac at a time, many paired
**Status:** accepted

The phone keeps any number of paired Macs but connects to one (switch in
Settings). This keeps the UI focused and the connection logic simple; the
demo Mac is just another `PairedMac` (`isDemo`).

### D-052 — Subscriptions follow what the user opened
**Status:** accepted

The session list is kept current by `sessionUpdated` pushes; full event
streams are subscribed only for sessions the user opened during the current
connection and are re-subscribed from `lastSeq + 1` after every reconnect.

### D-053 — SwiftData as an append-only transcript cache
**Status:** accepted

`CachedSession` (summary JSON) and `CachedEvent` (`<session>#<seq>` unique key,
event JSON) mirror what the Mac sent, so the app shows the last known
transcript offline and resumes catch-up from the cached position. The Mac
remains the source of truth; the cache can be cleared at any time.

### D-054 — Permission UX
**Status:** accepted

Requests appear as a bottom sheet (medium/large detents) wherever the user is,
with the oldest first. "Later" hides a request on this device only; the Mac
keeps it pending until answered or the 10-minute timeout denies it. A warning
haptic plays when a request arrives and a success haptic on approval.

### D-055 — String Catalogs generated from source
**Status:** accepted

`scripts/l10n/build_catalogs.py` extracts the same literals Xcode extracts
(converting interpolations to `%lld`/`%@`), merges the reviewed TR/DE
translations from `scripts/l10n/*_translations.py` and writes
`Localizable.xcstrings`; `infoplist.py` writes `InfoPlist.xcstrings`.
`--check` fails CI on missing translations. Notices produced by the Mac are
looked up as keys too, so common ones appear localised on the phone.

### D-056 — Export compliance
**Status:** accepted — confirm before the first App Store submission

The app uses only standard algorithms (X25519, ChaCha20-Poly1305, SHA-256 via
Apple CryptoKit) to protect the user's own data between their devices, which
falls under the mass-market exemption; `ITSAppUsesNonExemptEncryption` is set
to `NO`. The publisher should confirm this classification in App Store
Connect.

### D-057 — Privacy manifests
**Status:** accepted

`PrivacyInfo.xcprivacy`: no tracking, no collected data; `UserDefaults`
(reason `CA92.1`) on both platforms and file timestamps (`3B52.1`, folders the
user browses) on the Mac.

---

## Phase 4 — Tailscale setup assistant

### D-060 — The assistant is an ordinary Pilothouse session
**Status:** accepted

"Set Up with Claude" starts a normal session in `~` (permission mode
`default`) with the prompt from §7.2. It therefore appears on every paired
phone, streams like any session and needs approval for each command. The
prompt is sent in the Mac's preferred language (TR text verbatim from the
specification; EN/DE equivalents).

### D-061 — Approvals and replies on the Mac too
**Status:** accepted

Sessions started from the Mac must not depend on a phone being at hand, so the
Mac menu shows pending permission requests with Allow/Deny, and the Tailscale
window contains a compact transcript with a reply field (e.g. "I have signed
in") and a Stop button. Any device may answer a request; the first answer wins.

### D-062 — Detection and propagation
**Status:** accepted

Tailscale is detected via `/Applications/Tailscale.app/Contents/MacOS/Tailscale
status --json` or `tailscale` on `PATH` (stable JSON fields only:
`BackendState`, `Self.TailscaleIPs`, `Self.DNSName`, `CurrentTailnet`). The
assistant polls every 4 s until connected; afterwards the regular 30 s refresh
and network-change monitoring apply. A change is broadcast as `macStatus`;
phones persist the new addresses, and new pairing QR codes include them.

### D-063 — iOS remains a manual step
**Status:** accepted

iOS does not allow third-party apps to install or configure another VPN. The
phone shows a single explicit step (install Tailscale from the App Store, sign
in with the same account) and states why it cannot be automated (§7.4).

---

## Phase 5 — Tests

### D-070 — "MockMacServer" is the demo host service
**Status:** accepted

The UI tests' mock Mac (`MockMacServer`, a typealias of `DemoHostService`)
runs in the app process behind the real Noise channel, so UI tests need no
network, no Mac and no fixtures on disk, and they exercise the production
client code. A test-only "Simulate Network Drop" control (visible only with
`-UITesting` in demo mode) cuts the connection to test reconnection.

### D-071 — Real-CLI end-to-end test is opt-in
**Status:** accepted

`RealClaudeEndToEndTests` needs a signed-in `claude` and makes a small model
call, so it only runs when `PILOTHOUSE_E2E_CLAUDE` points to the CLI. It drives
the full host stack in-process (the iOS client logic is the same `MacClient`);
only the Network.framework socket is replaced by an in-memory transport.

### D-072 — Interrupted or closed CLIs are "retiring"
**Status:** accepted (bug found by D-071)

After Stop or Close the CLI may still be exiting. Such a process never receives
new input: the next message waits (≤ 10 s, then SIGKILL) until its exit — and its
last lines — have been processed, then a fresh CLI is started with `--resume`.

### D-073 — CI
**Status:** accepted

GitHub Actions: package tests in the official `swift:6.1` Linux image, and on
`macos-15` both Xcode schemes with `CODE_SIGNING_ALLOWED=NO` (Mac app + helper
build, package tests on macOS, iOS app build + UI tests on the newest iPhone
simulator). Result bundles are kept for 7 days.
