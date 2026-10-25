# Testing

Pilothouse is tested at four levels. Everything runs from the command line.

| Level | What | Where | Command |
|---|---|---|---|
| Unit | Protocol coding, Noise IK (cacophony vector), secure channel replay/reorder/tamper detection, pairing payload, handshake (MITM, clock skew, version mismatch, rejected token), path sandbox escapes, file browser, event log (torn lines, permissions), stream-json normaliser on **real captured CLI output**, MCP endpoint + HTTP parser, permission broker (timeout, cancel), process supervision (process groups, SIGTERM→SIGKILL), Markdown/diff presentation, Tailscale status parsing | `PilothouseKit/Tests` | `cd PilothouseKit && swift test` |
| Integration | `SessionManager` with **FakeClaude** (`Tests/PilothouseHostTests/Fixtures/fake-claude.sh`): start, stream, interrupt + resume, close + resume, crash and login notices, permission allow / remember / deny / timeout through the real loopback MCP server, retention, crash recovery | same | same |
| Full stack | `MacClient` → Noise channel → `ServerEndpoint` → `MacHostService` → `SessionManager` → FakeClaude → MCP → client approval; pairing and instant revocation | `FullStackTests` | same |
| End-to-end, real CLI | Pairing → session → **real `claude`** writes `hello.txt` after the permission prompt is approved on the client → close → `--resume` → follow-up remembers the file | `RealClaudeEndToEndTests` (opt-in) | `PILOTHOUSE_E2E_CLAUDE=$(command -v claude) swift test --filter RealClaudeEndToEndTests` |
| Notifications | Event → alert mapping (`NotificationRules`: phone vs. Mac turns, interrupts, crashes, error results), `NotificationService` against the hub and against FakeClaude, `NtfyPublisher` JSON/token/click link through a stub `URLProtocol`, `SessionLink` parsing | `NotificationTests` | `swift test --filter Notification` |
| Notifications, real ntfy | Publishes to a fresh random topic on ntfy.sh, expects HTTP 200 and reads the message back | `LiveNtfyTests` (opt-in) | `PILOTHOUSE_NTFY_LIVE=1 swift test --filter LiveNtfyTests` |
| Linux host (D-110) | Server side of `WebSocketCodec` (101 answer, masked client frames), `POSIXWebSocketListener` over real TCP (echo up to 1 MB, ping/pong, close, plain HTTP rejected, port search), phone-like client pairs and runs a FakeClaude turn | `WebSocketServerCodecTests`, `POSIXWebSocketListenerTests` | `swift test --filter 'POSIXWebSocket\|WebSocketServerCodec'` |
| Linux host, running server | Pairs with a running `pilothouse-server` (e.g. the Docker image) like the iPhone app, browses the home folder, starts a session | `LiveLinuxServerTests` (opt-in) | `PILOTHOUSE_LIVE_PAIR_LINK=<link from pair --no-wait> swift test --filter LiveLinuxServerTests` |
| UI (iOS) | Onboarding/pairing errors, demo Mac, seeded tool cards + diff, new session in a picked folder, message + permission approval / always-allow, denial, Stop, reconnection after a network drop | `PilothouseUITests` (XCUITest, demo Mac = `MockMacServer`) | `xcodebuild test -scheme PilothouseiOS -destination 'platform=iOS Simulator,name=iPhone 16'` |
| Screenshots | iPhone + iPad, light + dark, EN/TR/DE | `ScreenshotTests` | `scripts/screenshots.sh` |

`scripts/test.sh` runs the translation check, the package tests and — on a Mac —
both Xcode schemes (`CODE_SIGNING_ALLOWED=NO`, no developer account needed).
CI (`.github/workflows/ci.yml`) runs the package on Linux and both schemes on
macOS for every push to `main` and every pull request.

## Results of the build session (2026-10-24)

Environment: Linux x86_64, Swift 6.1.3 (Ubuntu 26.04 chroot), Claude Code
2.1.310. Xcode is not available there, so Apple-only code (SwiftUI apps,
Network.framework transport, IOKit, ServiceManagement, Keychain) is verified by
CI on macOS instead.

* `swift test` — **128 tests passed**, 1 skipped (the opt-in real-CLI test),
  stable over repeated runs (5×).
* Real-CLI end-to-end test — **passed in 5.8 s** with `haiku`: the permission
  request for `Write` reached the client over MCP, was approved, `hello.txt`
  contained "Hello from Pilothouse", and after close + resume Claude named the
  file correctly.
* The end-to-end test found a real bug before release: resuming right after
  closing (and sending right after Stop) wrote to the exiting CLI and the
  message was lost. Fixed in `SessionManager` ("retiring" processes) and
  covered by two regression tests.

## Results on macOS (GitHub Actions, 2026-10-24)

Environment: `macos-15` runner, Xcode 16.4, iPhone 17 Pro simulator (iOS 26.2).

* **PilothouseMac scheme** — Mac app, privileged helper and both package test
  targets build without warnings; **128 package tests passed** on macOS
  (59 + 69; the opt-in real-CLI test skipped).
* **PilothouseiOS scheme** — iOS app builds without warnings; **7 UI tests
  passed** (onboarding + demo, seeded tool cards and diff, new session with
  approval and "always allow", denial, Stop, reconnection after a network drop,
  screenshot capture) plus the package tests on the simulator.
* **Screenshots workflow** — 60 App Store screenshots (iPhone 17 Pro Max 6.9"
  and iPad Pro 13-inch (M5), light + dark, EN/TR/DE, 5 screens each) in 11
  minutes; kept as the `screenshots` artifact of the run for 90 days.
* The first macOS run found two problems that Linux could not: a `Mutex` copied
  into a Network.framework callback (compile error) and a UI test that did not
  scroll the lazy Settings form. Both fixed.

## Fixtures

`Tests/PilothouseHostTests/Fixtures/stream-*.jsonl` are real Claude Code
2.1.310 outputs (Write + Bash with an MCP permission prompt; an interrupted
turn; Read + Edit with extended thinking), anonymised: paths, session IDs,
account data and signatures were replaced.
