# Contributing to Pilothouse

Thanks for helping! Pilothouse is a small project with a few firm rules;
reading this first saves everyone a review round.

## Ground rules

* **Pilothouse never talks to Anthropic and never handles Claude credentials.**
  It only drives the official `claude` CLI on the user's Mac. Changes that call
  an API directly, read `~/.claude*`, or move credentials anywhere are not
  accepted.
* **No telemetry, no accounts, no servers.** Traffic stays between the user's
  own devices.
* **No third-party dependencies** on Apple platforms. (`swift-crypto` is used
  only on Linux, so the package can be tested there — D-013.) If you believe a
  dependency is unavoidable, open an issue first and explain why; the decision
  goes into `docs/DECISIONS.md`.
* **Security first.** Anything that touches pairing, the handshake, the file
  sandbox or the permission flow needs tests, and a short note in
  `docs/SECURITY.md` if the threat model changes. Report vulnerabilities
  privately (GitHub → Security → Report a vulnerability), not in issues.
* Respect the Claude Code brand: no Anthropic or Claude logos, colours or
  wording that suggests an official product.

## Getting started

```sh
git clone https://github.com/ardasnturk/pilot-house.git && cd pilot-house
cd PilothouseKit && swift test          # works on macOS and Linux
open ../Pilothouse.xcodeproj            # Xcode 26+, schemes PilothouseMac / PilothouseiOS
```

Code signing is not needed to build and test (`CODE_SIGNING_ALLOWED=NO`); to run
the apps on a device, select your own team in Xcode. `scripts/test.sh` runs
everything the current machine supports.

| Directory | What |
|---|---|
| `PilothouseKit/Sources/PilothouseKit` | Protocol, Noise IK crypto, transports, client, demo Mac, presentation helpers |
| `PilothouseKit/Sources/PilothouseHost` | Mac host core: `claude` processes, stream-json normaliser, permission MCP server, event log, file sandbox |
| `PilothouseMac`, `PilothouseHelper`, `Shared` | Menu bar app, privileged lid-closed helper |
| `PilothouseiOS`, `PilothouseUITests` | iPhone/iPad app and its UI tests |
| `scripts/` | Build, release, screenshots, localisation |
| `docs/` | Decisions, protocol, security, testing, release process |

## Coding conventions

* Swift 6 language mode with strict concurrency; SwiftUI, `@Observable`,
  async/await.
* **No force unwraps, no `try!`, no warnings.** CI builds with the default
  warning set and every warning counts as a bug.
* Keep platform-specific code out of `PilothouseKit` unless it is behind
  `#if canImport(...)`; the core must keep building on Linux.
* Match the surrounding style: small types, doc comments on public API, no
  commented-out code.
* User-facing strings are localised (English, Turkish, German). Write
  `Text("…")` / `String(localized:)` as usual, then add the translations to
  `scripts/l10n/ios_translations.py` or `mac_translations.py` and run
  `python3 scripts/l10n/build_catalogs.py`. CI fails on missing translations
  (`--check`).
* After editing `project.yml`, run `scripts/bootstrap.sh` and commit the
  regenerated `Pilothouse.xcodeproj` (D-036).

## Tests

* Unit and integration tests use Swift Testing (`PilothouseKit/Tests`); host
  tests use **FakeClaude** (`Tests/PilothouseHostTests/Fixtures/fake-claude.sh`)
  instead of the real CLI.
* If you change how stream-json is interpreted, add a real, anonymised capture
  to `Fixtures/` and a test for it.
* UI tests (`PilothouseUITests`) run against the in-app demo Mac; new screens
  need accessibility identifiers and, ideally, a UI test.
* The real-CLI end-to-end test is opt-in:
  `PILOTHOUSE_E2E_CLAUDE=$(command -v claude) swift test --filter RealClaudeEndToEndTests`.

See [docs/TESTING.md](docs/TESTING.md).

## Pull requests

1. Open an issue for anything bigger than a bug fix, so we can agree on the
   approach first.
2. Keep PRs focused; one topic per PR.
3. Make sure `scripts/test.sh` passes and CI is green.
4. Record new design decisions in `docs/DECISIONS.md` (next free `D-NNN`).
5. Describe what you changed and how you tested it.

By contributing you agree that your contribution is licensed under the
[MIT License](LICENSE).

## Adding a language

1. Add the language code to the generators in `scripts/l10n/` (see how `tr`
   and `de` are handled) and translate every key.
2. Add `metadata/ios/<locale>/` for the App Store texts, add the locale's
   non-affiliation phrase to `DISCLAIMER` in `scripts/check-metadata.py` and
   run it.
3. Add the language to `ScreenshotTests` / `scripts/screenshots.sh` if you want
   localised screenshots.
