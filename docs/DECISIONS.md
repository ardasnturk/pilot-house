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

---

## Phase 6 — Release

### D-080 — Mac app outside the Mac App Store
**Status:** accepted

The Mac app starts the user's own `claude` binary with the login-shell
environment, lets it work in any folder under the home folder and installs a
privileged helper for lid-closed mode. None of that is possible in the App
Sandbox, so the Mac app ships as a Developer ID–signed, notarized and stapled
DMG on GitHub Releases and through a Homebrew cask. The helper and the app
share team `5JMD3VSD7N`; the helper's XPC code-signing requirement depends on
that.

### D-081 — No push notifications in 1.0
**Status:** superseded by D-095

Background notifications need APNs, and APNs needs a server holding a push key.
That contradicts "only your own devices, no telemetry". 1.0 relies on the Mac:
permission requests wait (and are shown in the menu bar) until the phone
reconnects, and are denied after 10 minutes. An optional self-hostable relay
that only sees opaque wake-ups is on the roadmap.

### D-082 — Third-party names in store metadata
**Status:** accepted

"Claude Code" appears only nominatively — in the subtitle and the description,
to state compatibility and the requirement (App Review guidelines 2.3.7 and
5.2.1). It is not part of the app name, the icon or the keyword field, and
every description ends with the non-affiliation statement.

### D-083 — Metadata as plain files, checked in CI
**Status:** accepted

`metadata/ios/<locale>/*.txt` uses the directory layout of fastlane `deliver`,
so it can be uploaded with it, but nothing depends on fastlane (no third-party
dependencies). `scripts/check-metadata.py` enforces the App Store Connect
limits (name/subtitle 30, keywords 100 bytes, promotional text 170, …), the
"where to get the Mac app" sentence and the disclaimer; CI runs it.

### D-084 — Own Homebrew tap in this repository
**Status:** accepted

`Casks/pilothouse.rb` lives here, so the repository doubles as a tap
(`brew tap ardasnturk/remote-code https://github.com/ardasnturk/remote-code`).
`homebrew/cask` requires a released, notable app; it can be submitted there
later unchanged. Until the first DMG exists the cask uses `sha256 :no_check`;
`scripts/prepare-release.sh` writes the real version and checksum.

### D-085 — Release automation stops before anything irreversible
**Status:** accepted

The prompt allows automation up to, not including, irreversible steps.
`build-ios.sh` archives and uploads to App Store Connect (a TestFlight build
can simply be expired) and never submits for review. `prepare-release.sh`
creates a *draft* GitHub release. Publishing the release and submitting the app
for review are deliberate manual steps (docs/RELEASE.md).

### D-086 — Screenshots from UI tests on the demo Mac
**Status:** accepted

`ScreenshotTests` drives the demo Mac, so screenshots are reproducible, show no
private paths and need no real Mac. `scripts/screenshots.sh` sets a clean status
bar (9:41, full battery), switches light/dark, and runs EN/TR/DE through the
`SCREENSHOT_LANGUAGE` test-runner variable. The manual `Screenshots` workflow
runs the same script on a GitHub macOS runner and keeps the PNGs as an artifact
(the full set is too large to commit).

### D-087 — Privacy policy in the repository
**Status:** accepted

App Store Connect needs a privacy policy URL. `PRIVACY.md` (EN/TR/DE) states
that Pilothouse collects nothing, and is linked from the metadata. It matches
the privacy manifests (D-057) and the "Data Not Collected" privacy label.

## Release 1.0 — Agents, folders, sub-agents

### D-090 — Optional features as capabilities, protocol version stays 1
**Status:** accepted

Features keep adding messages and fields. Bumping `version` would lock older
phones out of newer Macs and the other way round. Instead the Mac lists optional features in
`helloAck.capabilities` (`createDirectory`, `agents`, `threads`); new fields
are optional and decoded with defaults; the phone only sends a new message or
field when the Mac lists the capability. Error codes were already open-ended.

### D-091 — Creating folders from the phone
**Status:** accepted

`createDirectory { parent, name }` reuses the home-folder sandbox (D-012 era
`PathSandbox`) for the parent and accepts exactly one visible path component
as the name (no `/`, `:`, leading dot or NUL, ≤ 255 bytes), so the new folder
can only be a direct child of an already checked folder. It answers with the
parent's listing so the phone can open the new folder immediately.

### D-092 — Agent adapters behind the session manager
**Status:** accepted

Codex and Gemini are driven through their own long-running stdio protocols
instead of one-shot `exec` runs, so sessions keep context, can be interrupted
and resumed, and approvals reach the phone. `SessionManager` keeps owning the
process (D-005, D-072); an `AgentAdapter` per process only turns output lines
into `SessionEvent`s and input into lines. Claude Code keeps `stream-json`
(`ClaudeAdapter` wraps the existing normaliser) and SIGINT interrupts; Codex and
Gemini interrupt over their protocols and keep the process.

* **Codex** — `codex app-server` (JSON-RPC, protocol v2), verified with Codex
  CLI 0.162.1: `thread/start|resume`, `turn/start|interrupt`, approvals via
  `item/commandExecution|fileChange/requestApproval`. Permission modes map to
  approval policy + sandbox: default → `untrusted`/`read-only`, acceptEdits →
  `on-request`/`workspace-write`, plan → `on-request`/`read-only` plus plan
  instructions, bypass → `never`/`danger-full-access`. The thread ID is stored
  as `SessionRecord.agentSessionId` for resume.
* **Gemini** — `gemini --experimental-acp` (Agent Client Protocol v1), written
  against the ACP schema; Gemini CLI 0.24.0 reports `loadSession: false`, so a
  closed Gemini session continues as a fresh conversation. Accounts that need
  `GOOGLE_CLOUD_PROJECT` fail `authenticate`; the error is shown as a sign-in
  notice. The Mac offers no ACP file-system or terminal capabilities, so the
  agent uses its own tools and asks before side effects.

Both protocols are marked experimental by their vendors. Unknown notifications
are ignored and unknown server requests get a JSON-RPC error, so newer CLIs
degrade instead of hanging.

### D-093 — Sub-agents via `delegate_to_agent`
**Status:** accepted

Claude Code delegates through a second tool on Pilothouse's existing loopback
MCP server (D-004), listed only for Claude sessions and only for agents the
Mac user enabled. The sub-agent runs in the session's folder and permission
mode; its approvals go through the same broker (and "always allow" list) as
the session's own, tagged with the agent's name. The call returns the
sub-agent's last message. It is stopped with the parent (interrupt, close,
delete) and after 60 minutes; the MCP request timeout was raised to 61 minutes
so Claude waits for it (permission prompts still time out after 10, D-054).

### D-094 — Sub-agent threads
**Status:** accepted

`SequencedEvent.thread` / `EventPayload.thread` carry the tool-use ID that
started a sub-agent (Claude `Task`, previously dropped, or
`delegate_to_agent`). Thread events share the session's sequence numbers and
log, so catch-up and the phone cache need no changes, but never change the
session's own state, title or preview. The phone folds them into a separate
transcript per thread, shows running sub-agents above the composer and opens a
thread in its own sheet from the tool card.

## Release 1.0 — Notifications

### D-095 — Notifications through ntfy and macOS, no own push server
**Status:** accepted · supersedes D-081

Pilothouse notifies the user when a turn started from a phone finishes, when Claude
waits for a permission decision and when a session fails. Apple push (APNs)
still needs a server holding a push key, so instead:

* **Mac:** native notifications (`UNUserNotificationCenter`). No
  terminal-notifier.
* **iPhone:** the Mac publishes to an [ntfy](https://ntfy.sh) topic with a plain
  HTTPS POST (JSON body); the user subscribes in the free ntfy iOS app, which
  handles Apple push. Default server `https://ntfy.sh`, any self-hosted server
  works (HTTPS only, because of App Transport Security). The topic is 32 random
  characters generated on first launch and acts as the password on a public
  server; an optional access token is kept in the Keychain and sent as
  `Authorization: Bearer`.
* **Minimal by default:** the message is "Task finished · <folder>" (or
  "Approval needed" / "Session failed"). The last message, the tool name or the
  error text are only added after opting into "Include a short summary".
* **Tap action:** ntfy's `click` is `pilothouse://session/<id>?mac=<macId>`
  (`SessionLink`); the iOS app switches to that Mac and opens the session.
* **Off by default.** Nothing leaves the Mac until the user turns notifications
  and the ntfy destination on in Settings → Notifications.
* **Subscribing:** the ntfy iOS app has no URL scheme (`ntfy://` links are
  Android-only; checked in ntfy-ios' Info.plist), so the settings QR code
  carries the topic's web address (`https://ntfy.sh/<topic>`, opens in Safari)
  next to "Copy Topic", step-by-step text and the App Store link.

`NotificationService` (PilothouseHost) only listens to the `NotificationHub`:
when a session leaves a busy state it waits 1.5 s (so trailing "interrupted" or
"process exited" notices land), replays the turn's events and decides with
`NotificationRules`. Interrupted turns stay silent; Mac-started turns (the
Tailscale assistant) only notify on failure. Turns count as "from a phone" when
they arrive through `MacHostService.startSession`/`sendMessage`. Sub-agent
tracking can post `HostAlert.Kind.subagentFinished` through
`NotificationService.post(_:)`; the kind is not offered in Settings until then.

The privacy manifests are unchanged: the data goes to a destination the user
picks and configures, not to the developer or a partner, and is off by default.
PRIVACY.md lists exactly what is sent.

## Release 1.0 — Weekly summary and usage limits

### D-096 — Weekly summary written on the Mac
**Status:** accepted

All session logs (30 days) live on the Mac; the phone only caches what it
opened. The Mac therefore builds the summary (`getWeeklySummary`) and the
phone only shows it.

* **Numbers** (`WeeklyStatsBuilder`, platform-neutral): per project folder the
  active time (sum of gaps under 15 minutes between events of all its sessions
  and sub-agents, so parallel sessions are not counted twice), sessions, turns
  per agent, files changed and lines from `fileEdit` diffs, commands run,
  output tokens; plus a per-day series for the chart.
* **Words** (`AppleWeeklyNarrator`, Mac app): Apple's on-device model through
  the Foundation Models framework, macOS 26+. Each project gets up to three
  bullets from a compact digest (titles, first sentences of requests and
  answers, edited files), then the week a headline and highlights, in the
  language the phone sends (`GetWeeklySummary.language`, the app's interface
  language; the Mac's when missing), even where the chats are in another one.
  The reason without a narrative follows it too. Nothing leaves the Mac. Without Apple Intelligence the
  summary carries the numbers and `narrativeUnavailableReason`; it can be
  turned off in Settings → Agents.
* **Cache:** `insights/<week-start>.json`; finished weeks are built once, the
  current week at most hourly unless the phone pulls to refresh. A summary in
  another language than the one asked for is rebuilt.

`DiffBuilder` no longer counts `---`/`+++` file headers as removed/added
lines (found while testing the line counts; it also inflated the "+N −M" on
tool cards for diffs with headers).

### D-097 — Usage limits as reported by the CLIs
**Status:** accepted

Pilothouse never calls the vendors' APIs (see "Not planned"), so limits are
whatever the CLIs report, stored in `usage-limits.json`:

* **Claude Code** sends `rate_limit_event` with every turn: account-wide
  `five_hour` and `seven_day` utilisation and reset times (not per model).
  Shown as "as of the last turn"; no extra model call is made to refresh it.
* **Codex** answers `account/rateLimits/read` without a model call, with
  windows per metered bucket (per model when it has several). The Mac reads
  it on request (at most once a minute) through a short-lived
  `codex app-server`, and keeps `account/rateLimits/updated` from turns.
* **Gemini CLI** reports nothing; shown as unavailable.

### D-098 — The `/` menu: skills and commands with descriptions
**Status:** accepted

Claude Code's `system/init` lists every slash command (`slash_commands`),
which of them are skills (`skills`) and the installed plugins with their
folders. The Mac keeps those per session and answers `listCommands` with each
entry's kind, source and description, read from the same files Claude Code
loads: `<cwd>/.claude/{skills,commands}` (project), `~/.claude/...`
(personal), then plugin folders (namespaced `plugin:name` entries); the rest
is built in, with short descriptions for the common built-in commands. Only
the `description` front-matter field (or the first line) is read and clipped
to 280 characters; skill bodies never leave the Mac. Names starting with `_`
are internal and hidden.

On the phone, typing `/` into an empty composer opens a searchable sheet with
skills and commands in separate sections (filter, source badge); choosing
one inserts `/name `. Codex and Gemini report no catalogue, so their sessions
say so.

### D-099 — LAN connections wait for the Local Network decision
**Status:** accepted

iOS's Local Network privacy blocks outgoing TCP to LAN addresses until the
user allows it; Tailscale traffic goes through a VPN interface and is not
affected (TN3179). While the alert is on screen the system may deny the
connection at once, and Network.framework reports `.waiting` with
`unsatisfiedReason == .localNetworkDenied`. 1.0 treated every `.waiting` as a
failure, so a phone on the same Wi-Fi gave up before the user could answer
and only connected over Tailscale.

Now `.waiting` keeps the attempt alive until its timeout (Network.framework
retries by itself; only `ECONNREFUSED` fails at once). Pairing, usually the
app's first LAN access, waits up to 30 s more while the path is denied, and
the pairing screen starts Bonjour browsing so the alert appears before the QR
code is scanned. If an attempt ends while access is still denied the client
reports `localNetworkDenied`: pairing says so with an "Open Settings" button,
and the connection banner shows "Local Network access is off" with a Settings
button instead of Retry. The Mac needs no change: accepting incoming TCP is
not subject to Local Network privacy.

### D-100 — Model and effort per chat
**Status:** accepted

`claude` takes `--effort low|medium|high|xhigh|max`; `codex app-server`
takes `effort` with each `turn/start`. New chats get the effort chosen on the
phone (default in Settings → New chats); `Session.effort` carries it.

`updateSessionSettings` changes a chat's model and/or effort between turns.
Rather than relying on undocumented in-process switches, the Mac stops the
idle CLI; the next message starts it again with `--resume` (Codex:
`thread/resume`) and the new flags, so the conversation continues with the new
settings. While a turn runs the request is refused. On the phone the model
chip in the composer and the session menu offer Model and Effort pickers.

### D-101 — The `/` menu works before the first message
**Status:** accepted

Claude Code reports its commands only in `system/init`, which a new chat has
not seen yet, so the 1.0 menu was empty until the first reply. `listCommands`
now merges that report with what is on disk: skills
(`skills/<name>/SKILL.md`) and commands (`commands/*.md`, sub-folders as
`folder:name`) of the project and of `~/.claude`, plugins enabled in
`~/.claude/settings.json` (install folders from
`plugins/installed_plugins.json`, entries namespaced `plugin:name`), and the
built-in commands. The composer also gets a visible `/` button for the list.

### D-102 — Models and effort levels come from the CLIs
**Status:** accepted

Hard-coded model lists ("opus", "sonnet", "haiku") went stale and showed raw
IDs such as `claude-sonnet-5-5`. The CLIs know better and say so without a
model call: Claude Code answers the stream-json `initialize` control request
with `models` (alias, resolved model, display name, description,
`supportedEffortLevels`, which one is the default), and `codex app-server`
answers `model/list` (display name, `supportedReasoningEfforts`,
`defaultReasoningEffort`, `isDefault`, hidden models). The Mac asks both when
it refreshes the agents (short-lived processes, like the Codex limit reader)
and sends them as `AgentStatus.modelOptions` (capability `modelCatalog`).
Claude's default effort is `effortLevel` from `~/.claude/settings.json`.

The phone shows display names everywhere (also for the model a session
reports), lists dated models under "Earlier models", and offers only the effort
levels of the chosen model. The Mac accepts any lower-case level word for
agents with an effort setting; the CLI rejects what its model does not take.

### D-103 — Local network first, Tailscale only on request
**Status:** accepted

1.0 tried the last working address first, so after one Tailscale connection
the phone kept preferring Tailscale even at home, and the Tailscale guidance
read as a requirement. Now the planner always tries the LAN (Bonjour, LAN
addresses, the last working LAN address) first; Tailscale addresses come
after them and only when the user turned on "Use Tailscale when away" in the
iPhone settings (`ConnectionPreference.automatic`; the default is
`localOnly`). Someone who chose "Tailscale only" in 1.0 keeps Tailscale on.
When the Mac is not reachable and it has Tailscale addresses, the connection
card offers "Use Tailscale". On the Mac, Tailscale moved from the menu into
Settings → Remote Access, explained as optional.

### D-104 — 1.1 design: brand gradient, glass, sheets
**Status:** accepted

Both apps share a teal → indigo → violet brand gradient. iPhone: a mesh
gradient behind every screen (lighter behind the chat), translucent cards, a
gradient hero card for the Mac connection with plain next steps when offline,
gradient message bubbles and buttons. Tool calls and thinking are compact rows
that open a sheet with the details (diff, command output, file), as in the
Claude and Codex apps; the task list stays inline. While a turn runs, the
agent's status, current tool and a timer sit inside the message field, which
gets a gradient outline, and Send becomes Stop.

Mac: the menu has a gradient header with the status and three counters, then
only what matters now (setup problems, approvals, an available update, pairing,
chats, limits, keep awake). Addresses, devices, agents and Tailscale moved to
Settings, which is now a sidebar of panes with coloured icons like System
Settings. The DMG window uses the same gradient with glass tiles and the next
steps.

### D-105 — The Mac app updates itself from GitHub Releases
**Status:** accepted

No Sparkle (no third-party dependencies). `AppUpdater` reads
`releases/latest` once a day (setting, on by default) and on demand, ignores
drafts and prereleases and compares semantic versions. Installing downloads
the DMG, checks it against the release's `.sha256` asset, mounts it read-only,
copies the app out, and verifies `codesign --deep --strict`, the same Team ID
as the running app and Gatekeeper (`spctl`). A detached script then waits for
the app to quit, swaps the bundle (restoring the old one if the copy fails),
removes the quarantine attribute and opens the new version. Where the bundle
cannot be replaced (run from the DMG, translocated, not writable) the release
page opens instead. Nothing is installed without a click.

### D-106 — Photos and videos as attachments
**Status:** accepted

The agent CLIs take images, not video. The composer's + menu offers the photo
library (photos and videos, up to six items) and the camera (photos only, so no
microphone permission is needed). A video becomes six frames taken from the
middle of six equal slices, plus a line in the message saying they are frames
of a video of a given length. Images are JPEG, at most 2048 px, under the
5 MB protocol limit; a message carries at most 20. Thumbnails of what this
device sent are kept in memory and shown in the bubble; tapping one opens it.

### D-107 — Guidance in plain steps, more languages
**Status:** accepted

The welcome screen, the README (new Quick start and Troubleshooting) and the
Mac menu now say what to do in numbered steps and in the words the apps use.
Both apps follow the device language and ship English, Turkish, German,
Spanish, French, Italian, Brazilian Portuguese, Japanese, Korean and
Simplified Chinese. Turkish and German stay in `scripts/l10n/<app>_translations.py`;
the other languages are `scripts/l10n/<app>.<language>.json` files read by
`build_catalogs.py`. iOS Settings explains how to pick another language just
for Pilothouse.

### D-108 — The phone speaks WebSocket over plain TCP itself
**Status:** accepted

On the same Wi-Fi the phone could not pair or connect, while Tailscale worked.
Measured on an iPhone with iOS 26 (Local Network allowed, Bonjour finding the
Mac, Safari and `URLSession` reaching it): every `NWConnection` with
Network.framework's WebSocket protocol to the Mac's LAN address went to
`.waiting(ECONNABORTED, "Software caused connection abort")` right after the
TCP handshake — the Mac saw SYN, SYN-ACK and a FIN without a byte of data —
whatever the TCP options, message size or proxy settings. A plain TCP
`NWConnection` with the same parameters became `.ready`. Over Tailscale's VPN
interface the WebSocket client was not affected.

The phone therefore no longer uses Network.framework's WebSocket client:
`TCPWebSocketTransport` opens a plain TCP connection and speaks RFC 6455
itself (`WebSocketCodec`: the opening handshake with `Sec-WebSocket-Accept`
check, masked binary frames, ping/pong, close, fragmented messages). The Mac
keeps its Network.framework WebSocket server, so old and new phones both
connect. Connections also set `preferNoProxies`; the pairing error shows the
connection states per address, so a failure like this one can be told apart
from a network that keeps devices apart.

### D-109 — Changing a chat's permission mode, "Allow everything in this chat"
**Status:** accepted

Approving every command of a long task one by one is tiring, and the
permission mode could only be chosen when a chat started. Now it can change
at any time (`updateSessionSettings.permissionMode`, capability
`sessionPermissionMode`): from the chat's menu (Permissions) and, for
`bypassPermissions`, with "Allow everything in this chat" on the permission
sheet.

* **During a reply** the CLI keeps running. Pilothouse answers the CLI's
  prompts itself, so `bypassPermissions` takes effect at once: the chat's open
  requests are allowed and later ones are allowed without asking (logged like
  "always allow" decisions). After the reply the CLI is restarted with
  `--resume` and the new flag, as for a model change.
* **Still opt-in on the Mac** (D-006): without "Allow bypass permissions" in
  the Mac's settings the Mac refuses the change (`modeNotAllowed`) and the
  sheet explains where to turn it on.
* The chat shows a notice when its mode changes.

### D-110 — Renamed to Remote Code
**Status:** accepted

"Pilothouse" did not say what the app does. The apps, the repository
(`ardasnturk/remote-code`), the Homebrew cask and the icon (a `>_` prompt with
a signal instead of the helm) now say Remote Code. What other copies depend on
keeps the old name, so nothing has to be paired or set up again: the bundle
identifiers (`com.ardasenturk.Pilothouse.*`, which also tie the iOS app to its
App Store record and the helper to the app), the pairing link scheme
`pilothouse://`, the Bonjour type `_pilothouse._tcp`, the handshake prologue,
the keychain label, the data folder `~/Library/Application Support/Pilothouse`,
the MCP server name and the code's module and target names.

The Mac app is now `Remote Code.app` and its release image
`RemoteCode-<version>.dmg`. Copies up to 1.1.2 look for
`Pilothouse-<version>.dmg` with `Pilothouse.app` inside, so each release also
carries that bridge image; its app is the same signed build in a folder named
`Pilothouse.app`. The updater now installs the new bundle under its own name
next to the old one's place, so the next update after the bridge ends as
`Remote Code.app`. `cask_renames.json` moves Homebrew users from `pilothouse`
to `remote-code`.
