<p align="center"><img src="docs/icon.png" width="128" height="128" alt="Pilothouse icon"></p>

<h1 align="center">Pilothouse</h1>

<p align="center">Drive <b>Claude Code</b>, <b>Codex</b> and <b>Gemini CLI</b> on your Mac from your iPhone or iPad.</p>

<p align="center">
  <a href="https://github.com/ardasnturk/pilot-house/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/ardasnturk/pilot-house?label=release"></a>
  <a href="https://github.com/ardasnturk/pilot-house/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/ardasnturk/pilot-house/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="Platforms" src="https://img.shields.io/badge/platforms-macOS%2015%2B%20%7C%20iOS%2018%2B-blue">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-green"></a>
</p>

<p align="center"><a href="https://pilot.ardasnturk.com">Website</a> · <b>English</b> · <a href="README.tr.md">Türkçe</a></p>

> **Pilothouse works with Claude Code, Codex and Gemini CLI.** It is an
> independent open-source project and is **not affiliated with, endorsed by or
> sponsored by Anthropic, OpenAI or Google**. You are responsible for using
> those tools in line with their terms.

Pilothouse is two apps and a shared Swift package:

* **Pilothouse for Mac** — a small menu bar app that starts and supervises the
  official agent command-line tools on your Mac (`claude`, `codex`, `gemini`),
  keeps the Mac awake and forwards everything to your paired devices.
* **Pilothouse for iPhone & iPad** — start sessions in any project folder,
  follow responses, thinking, tool calls, diffs and terminal output live, and
  approve or deny every action.

Pilothouse **never talks to Anthropic, OpenAI or Google** and never touches your
credentials: your own CLIs do all the AI work, signed in with your own
accounts. There is no server, no account and no telemetry — only your devices,
end-to-end encrypted.

## Features

* **Every agent you have** — pick Claude Code, Codex or Gemini CLI for a new
  chat; Pilothouse finds what is installed on the Mac.
* **Sub-agents** — Claude can hand a task to Codex or Gemini
  (`delegate_to_agent`); Claude's own `Task` sub-agents are shown too. Follow
  each one live in its own window and approve its actions on your phone.
* **Approve from anywhere** — edits with diffs, commands, *always allow* per
  session; nothing runs unanswered for more than 10 minutes.
* **Skills and commands** — type `/` for a searchable list of your skills and
  slash commands, with descriptions and where they come from.
* **Weekly summary and limits** — what you worked on, per project and day,
  written on the Mac by Apple Intelligence; usage limits of Claude and Codex
  with their reset times.
* **Folders** — browse your home folder and create new project folders from
  the phone.
* **Notifications** — native macOS and, through [ntfy](https://ntfy.sh), on
  your phone when a task finishes or needs approval.
* **Private by design** — Noise IK end-to-end encryption, pinned keys, no
  server; Tailscale for access from anywhere.

## Contents

* [Requirements](#requirements)
* [Install](#install)
* [Pair your phone](#pair-your-phone)
* [Using Pilothouse](#using-pilothouse)
* [Away from home: Tailscale](#away-from-home-tailscale)
* [Keeping the Mac awake](#keeping-the-mac-awake)
* [Security model](#security-model)
* [FAQ](#faq)
* [Building from source](#building-from-source)
* [Contributing](#contributing)
* [License](#license)

## Requirements

| | |
|---|---|
| Mac | macOS 15 Sequoia or later, Apple silicon or Intel |
| iPhone / iPad | iOS / iPadOS 18 or later |
| Claude Code | The official CLI installed on the Mac ([setup guide](https://docs.claude.com/en/docs/claude-code/setup)) and signed in with **your own Claude account** — or your own Anthropic API key |
| Codex, Gemini CLI | Optional. Installed and signed in on the Mac (`codex login`, `gemini`) |
| Weekly summary | Optional. macOS 26 with Apple Intelligence on the Mac for the written part; the numbers work everywhere |
| Network | Both devices on the same network, or both on your [Tailscale](https://tailscale.com) tailnet |

## Install

**Mac app** — download the notarized `Pilothouse-<version>.dmg` from
[GitHub Releases](https://github.com/ardasnturk/pilot-house/releases), or use
Homebrew:

```sh
brew tap ardasnturk/pilothouse https://github.com/ardasnturk/pilot-house
brew install --cask pilothouse
```

Open Pilothouse; its icon appears in the menu bar. If Claude Code is missing or
not signed in, the app shows a short setup guide
(`curl -fsSL https://claude.ai/install.sh | bash`, then `claude` once in
Terminal to sign in).

**iPhone / iPad app** — through TestFlight, Apple's free app for beta apps:
open **[testflight.apple.com/join/6CE4VRRE](https://testflight.apple.com/join/6CE4VRRE)**
on your iPhone or iPad (or scan the QR code on the
[website](https://pilot.ardasnturk.com)), install TestFlight if asked, then
**Install** Pilothouse. Inside the app, **Try the Demo** shows everything with a
simulated Mac.

## Pair your phone

1. On the Mac: menu bar icon → **Pair New Device…**. A QR code appears; it is
   valid for 5 minutes and can be used once.
2. On the phone: **Pair with Your Mac** → scan the code. Allow *Local Network*
   when iOS asks.
3. Both screens show the same **verification code**. Done — the Mac and the
   phone now trust each other's keys.

Lost a device? Mac menu → **Paired devices** → **Revoke**. Its connections are
dropped immediately.

## Using Pilothouse

* **New Chat** → **Where:** browse the folders in your Mac's home folder
  (favorites, recent folders, Git repositories are marked, **New Folder**
  creates one) → **Who:** Claude Code, Codex or Gemini → **How:** model and
  permission mode → **Start in …**. Permission modes:
  * *Ask every time* (default) — every action that needs approval is sent to
    your phone,
  * *Accept edits* — file edits are applied, commands still ask,
  * *Plan* — Claude only plans,
  * *Bypass permissions* — only after you allow it in the Mac settings; shown
    in red.
* **Permission requests** appear as a sheet with what Claude wants to do: the
  diff of an edit, the command it wants to run. *Allow*, *Deny*, or *Always
  allow … in this session*. Requests that nobody answers are **denied after
  10 minutes**.
* **Stop** ends the running turn immediately (like Ctrl-C). Your next message
  continues the same conversation.
* **Sessions** lists every session Pilothouse ran on the Mac (kept for 30 days).
  Open one to read it — offline too — or continue it with full context.
* **`/`** in an empty message field opens all skills and slash commands of the
  session, searchable, skills and commands listed separately.
* **Sub-agents** appear as cards with a coloured rail and as chips above the
  message field while they run; **Follow Live** opens their transcript.
* **This week** above the session list shows the time you worked and your
  usage limits; tap it for the weekly summary and the **Limits** tab.
* On the Mac, the menu bar shows running sessions, pending approvals and usage
  limits; you can answer approvals there as well. **Settings → Agents** lists
  the CLIs found and which ones Claude may delegate to.

## Away from home: Tailscale

At home or in the office the phone finds the Mac with Bonjour
(`_pilothouse._tcp`, port 47823 or the next free one). Elsewhere, Pilothouse
uses [Tailscale](https://tailscale.com), a free private network between your
devices:

* Mac menu → **Tailscale** → **Set Up with Claude**: Pilothouse opens a Claude
  Code session that installs and configures Tailscale step by step and stops
  whenever your password or a browser sign-in is needed — every command needs
  your approval, on the Mac or on the phone. Prefer to do it yourself?
  **Set Up Manually** shows the steps.
* On the phone: install the Tailscale app from the App Store and sign in with
  the same account. Pilothouse then tries the last working route, Bonjour, the
  local IP addresses and finally the Tailscale address automatically.

## Keeping the Mac awake

While Pilothouse runs it holds a *prevent idle system sleep* assertion: the
display may turn off, the Mac stays reachable. Optional **Stay awake with the
lid closed** (Mac settings → General) uses a tiny privileged helper whose only
ability is `pmset -a disablesleep 0/1`. It is switched off automatically on
battery (configurable) and reverted when Pilothouse quits. A closed MacBook that
stays awake can get warm — use it on a desk, not in a bag.

## Security model

* **Pairing:** the QR code contains the Mac's public key and a one-time token.
  An attacker on the network cannot impersonate the Mac: only the holder of the
  matching private key can complete the handshake.
* **Every connection:** `Noise_IK_25519_ChaChaPoly_SHA256` — mutual
  authentication with pinned X25519 keys, fresh session keys, ChaCha20-Poly1305,
  strictly increasing nonces, timestamps (replays are rejected).
* **Files:** the phone can only browse and start sessions inside your home
  folder; paths are normalised and symlinks resolved before the check.
* **Approvals:** Claude Code's own permission system stays in charge;
  Pilothouse forwards its prompts through a localhost-only MCP endpoint
  protected by a per-session token.
* **Credentials:** Pilothouse never reads, stores or transmits your Claude
  login. The optional API key (Mac settings → Claude Code) is kept in the
  Keychain and only passed to `claude` as `ANTHROPIC_API_KEY`.
* **Data:** session logs on the Mac (mode 0600, deleted after 30 days), a cache
  on the phone, keys in the Keychain. Nothing else, nowhere else.

Details: [docs/SECURITY.md](docs/SECURITY.md) · protocol:
[docs/PROTOCOL.md](docs/PROTOCOL.md) · privacy: [PRIVACY.md](PRIVACY.md).
Please report vulnerabilities privately through *Security → Report a
vulnerability*.

## FAQ

**Does Pilothouse need a Claude subscription?**
It needs whatever your Claude Code CLI needs — a Claude account with Claude
Code access or an Anthropic API key. Pilothouse itself is free.

**Does my code leave my Mac?**
Only the way it already does with Claude Code: the CLI talks to Anthropic as
usual. Pilothouse adds an encrypted link to *your* phone and nothing else.

**Why is the Mac app not on the Mac App Store?**
It must run your own `claude` binary with your shell environment and work in
any of your folders, which the App Store sandbox does not allow (D-080). It is
signed with Developer ID and notarized by Apple.

**Can I use my phone over mobile data?**
Yes, with Tailscale (see above). Without it, the phone must be on the same
network as the Mac.

**What happens when the phone disconnects mid-turn?**
Nothing is lost. Claude keeps working on the Mac; when the phone reconnects it
catches up from the session log. Permission requests wait for you (up to
10 minutes).

**Notifications?**
Under Settings → Notifications on the Mac (off by default): native
macOS notifications and, through [ntfy](https://ntfy.sh), notifications on your
iPhone when a task you started from the phone finishes, Claude waits for
approval or a session fails. Subscribe to the generated topic in the free ntfy
app; tapping a notification opens the session in Pilothouse. By default only
"Task finished · <folder>" is sent (D-095).

**Where are the logs?**
`~/Library/Application Support/Pilothouse/sessions/<session-id>.jsonl`.

**How do I uninstall?**
Quit Pilothouse and delete it (or `brew uninstall --zap --cask pilothouse`).
Remove `~/Library/Application Support/Pilothouse` and the "Pilothouse identity
key" items in Keychain Access for a clean slate.

## Building from source

```sh
git clone https://github.com/ardasnturk/pilot-house.git && cd pilot-house
open Pilothouse.xcodeproj          # Xcode 26 or later; schemes PilothouseMac / PilothouseiOS
scripts/test.sh                    # all tests that this machine can run
```

* `PilothouseKit/` — protocol, crypto, client, demo Mac (`PilothouseKit`) and
  the Mac host core (`PilothouseHost`); builds and tests on Linux too
  (`swift test`).
* `PilothouseMac/`, `PilothouseHelper/`, `PilothouseiOS/` — the apps.
* `project.yml` — XcodeGen spec; run `scripts/bootstrap.sh` after changing it.
To run the iPhone app on your own device, open the `PilothouseiOS` target →
*Signing & Capabilities* → choose your team, and run it from Xcode.

* Releases: [docs/RELEASE.md](docs/RELEASE.md). Changes:
  [CHANGELOG.md](CHANGELOG.md). Tests:
  [docs/TESTING.md](docs/TESTING.md). Design decisions:
  [docs/DECISIONS.md](docs/DECISIONS.md).

No third-party dependencies on Apple platforms.

## Contributing

Issues and pull requests are welcome — please read
[CONTRIBUTING.md](CONTRIBUTING.md) and the [code of conduct](CODE_OF_CONDUCT.md)
first. Translations live in `scripts/l10n/`; adding a language is a great first
contribution. Security problems: see [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE) © 2026 Arda Şentürk.

"Claude" and "Claude Code" are trademarks of Anthropic, PBC; "Codex" of OpenAI;
"Gemini" of Google LLC; "Tailscale" of Tailscale Inc. They are used here only
to describe compatibility.
