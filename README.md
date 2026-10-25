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

* [Quick start](#quick-start)
* [Requirements](#requirements)
* [Install](#install)
* [Pair your phone](#pair-your-phone)
* [Using Pilothouse](#using-pilothouse)
* [Updates](#updates)
* [Away from home: Tailscale (optional)](#away-from-home-tailscale-optional)
* [Troubleshooting](#troubleshooting)
* [Keeping the Mac awake](#keeping-the-mac-awake)
* [Security model](#security-model)
* [FAQ](#faq)
* [Building from source](#building-from-source)
* [Contributing](#contributing)
* [License](#license)

## Quick start

You need a Mac, an iPhone or iPad, and both on **the same Wi-Fi**.

1. **Install Pilothouse on the Mac** — download the DMG from
   [Releases](https://github.com/ardasnturk/pilot-house/releases/latest), drag
   Pilothouse into Applications and open it. A **helm icon** appears in the menu
   bar at the top of the screen; everything on the Mac starts there.
2. **Have an agent ready** — Claude Code (or Codex, Gemini CLI) installed and
   signed in once in Terminal. If it is missing, the helm menu shows an orange
   card with the exact commands.
3. **Install Pilothouse on the iPhone** — see [Install](#install).
4. **Pair** — on the Mac, click the helm icon → **Pair iPhone or iPad…**; on the
   phone, tap **Scan the Pairing Code** and point the camera at the QR code.
   Allow **Local Network** when iOS asks. Both screens show the same code.
5. **Start a chat** — on the phone, tap **New Chat**, pick a project folder on
   the Mac and type what you want. The agent works on the Mac; you watch every
   step and approve changes on the phone.

That's all. Tailscale is not needed at home; turn it on only if you want to use
Pilothouse away from your Wi-Fi ([below](#away-from-home-tailscale-optional)).

**No Mac?** A Raspberry Pi or any Linux machine works too: `pilothouse-server`
runs the same host in Docker, with Node.js, Expo and web tooling for Claude.
See [linux/README.md](linux/README.md).

## Requirements

| | |
|---|---|
| Mac | macOS 15 Sequoia or later, Apple silicon or Intel — or a 64-bit Linux machine such as a Raspberry Pi ([linux/](linux/README.md)) |
| iPhone / iPad | iOS / iPadOS 18 or later |
| Claude Code | The official CLI installed on the Mac ([setup guide](https://docs.claude.com/en/docs/claude-code/setup)) and signed in with **your own Claude account** — or your own Anthropic API key |
| Codex, Gemini CLI | Optional. Installed and signed in on the Mac (`codex login`, `gemini`) |
| Weekly summary | Optional. macOS 26 with Apple Intelligence on the Mac for the written part; the numbers work everywhere |
| Network | Both devices on the same Wi-Fi; optionally [Tailscale](https://tailscale.com) for access from elsewhere |

## Install

**Mac app** — download the notarized `Pilothouse-<version>.dmg` from
[GitHub Releases](https://github.com/ardasnturk/pilot-house/releases), or use
Homebrew:

```sh
brew tap ardasnturk/pilothouse https://github.com/ardasnturk/pilot-house
brew install --cask pilothouse
```

Open Pilothouse; its helm icon appears in the menu bar. If Claude Code is
missing or not signed in, the app shows a short setup guide
(`curl -fsSL https://claude.ai/install.sh | bash`, then `claude` once in
Terminal to sign in).

**iPhone / iPad app** — on TestFlight, Apple's free app for beta apps: scan
the code with your iPhone's camera or open
<https://testflight.apple.com/join/6CE4VRRE> on the device. The Mac app shows
the same code under **Get the iPhone App**. Inside the app, **Try the Demo**
shows everything with a simulated Mac.

<img src="docs/testflight-qr.png" alt="QR code for the TestFlight link" width="180">

## Pair your phone

1. On the Mac: helm icon → **Pair iPhone or iPad…**. A QR code appears; it is
   valid for 5 minutes and can be used once.
2. On the phone: **Scan the Pairing Code** → point the camera at it. Allow
   *Local Network* when iOS asks — without it the phone cannot reach the Mac on
   your Wi-Fi.
3. Both screens show the same **verification code**. Done — the Mac and the
   phone now trust each other's keys.

Lost a device? Mac **Settings → iPhone & iPad** → **Revoke**. Its connections
are dropped immediately.

## Using Pilothouse

* **New Chat** → **Where:** browse the folders in your Mac's home folder
  (favorites, recent folders, Git repositories are marked, **New Folder**
  creates one) → **Who:** Claude Code, Codex or Gemini → **How:** model,
  effort and permission mode → **Start in …**. The model and effort lists come
  from the agent itself, so they always match what your CLI offers. Permission
  modes:
  * *Ask every time* (default) — every action that needs approval is sent to
    your phone,
  * *Accept edits* — file edits are applied, commands still ask,
  * *Plan* — the agent only plans,
  * *Bypass permissions* — only after you allow it in the Mac settings; shown
    in red.
* **In a chat** the message field has everything: **+** attaches photos,
  videos (sent as a few frames) or a camera shot, **/** lists the skills and
  slash commands, and the **model chip** changes the model and effort of this
  chat. While the agent works, its current step and a timer show inside the
  field and the send button turns into **Stop**.
* **Tool calls** (reads, edits, commands, searches) are compact rows; tap one
  to see the diff, the command output or the file in a sheet.
* **Permission requests** appear as a sheet with what the agent wants to do.
  *Allow*, *Deny*, or *Always allow … in this session*. Requests that nobody
  answers are **denied after 10 minutes**.
* **Sessions** lists every chat Pilothouse ran on the Mac (kept for 30 days).
  Open one to read it — offline too — or continue it with full context.
* **Sub-agents** appear with a coloured rail and as chips above the message
  field while they run; **Follow Live** opens their transcript.
* **This week** above the chats shows the time you worked and your usage
  limits; tap it for the weekly summary and the **Limits** tab.
* **Language** — the apps follow the device language: English, Türkçe,
  Deutsch, Español, Français, Italiano, Português (Brasil), 日本語, 한국어 and
  简体中文. Choose another one per app in iOS Settings → Apps → Pilothouse.
* On the Mac, the helm menu shows running chats, pending approvals and usage
  limits; you can answer approvals there as well. **Settings** has panes for
  devices, agents, notifications, remote access, updates and security.

## Updates

The Mac app checks GitHub for a new release once a day (Settings → Updates).
When one is available, the helm menu shows it; **Install and Relaunch**
downloads it, checks its checksum, Apple notarization and developer signature,
replaces the app and opens the new version. Homebrew users can also run
`brew upgrade --cask pilothouse`. The iPhone app updates through TestFlight.

## Away from home: Tailscale (optional)

Pilothouse always connects over your local network first; the phone finds the
Mac by itself (Bonjour, `_pilothouse._tcp`, port 47823 or the next free one).
To use it **away from that Wi-Fi** — on mobile data, at a café — add
[Tailscale](https://tailscale.com), a free private network between your own
devices:

1. **Mac:** Settings → **Remote Access** → **Set Up Tailscale…**. Either let
   Claude set it up step by step (every command needs your approval) or follow
   the manual steps.
2. **iPhone:** install the Tailscale app from the App Store and sign in with
   the same account.
3. **Pilothouse on the iPhone:** Settings → turn on **Use Tailscale when
   away**.

With it on, Pilothouse still tries the local network first and uses Tailscale
only when the Mac is not reachable there. Off (the default), it never uses
Tailscale.

## Troubleshooting

**The phone says "Offline" at home.** Check, in this order: Pilothouse is
running on the Mac (helm icon in the menu bar); both devices are on the same
Wi-Fi (not a guest network — those often block devices from seeing each
other); iOS Settings → Privacy & Security → **Local Network** → Pilothouse is
on. The phone shows a button for the last one when it is off.

**Claude Code / Codex is "not signed in".** Open Terminal on the Mac, run
`claude` (or `codex login`) once and sign in, then choose **Check Again** in
Settings → Agents.

**Pairing code expired.** Codes last 5 minutes; choose **Pair iPhone or
iPad…** again.

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
Yes, with Tailscale (see [above](#away-from-home-tailscale-optional)). Without
it, the phone must be on the same Wi-Fi as the Mac.

**What happens when the phone disconnects mid-turn?**
Nothing is lost. Claude keeps working on the Mac; when the phone reconnects it
catches up from the session log. Permission requests wait for you (up to
10 minutes).

**Notifications?**
In the Mac app's Settings → Notifications (off by default): native
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
