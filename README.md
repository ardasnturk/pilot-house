<p align="center"><img src="docs/icon.png" width="128" height="128" alt="Pilothouse icon"></p>

<h1 align="center">Pilothouse</h1>

<p align="center">Drive the <b>Claude Code</b> CLI on your Mac from your iPhone or iPad.</p>

<p align="center"><b>English</b> · <a href="README.tr.md">Türkçe</a></p>

> **Pilothouse works with Claude Code.** It is an independent open-source
> project and is **not affiliated with, endorsed by or sponsored by Anthropic**.
> You are responsible for using Claude Code in line with
> [Anthropic's terms](https://www.anthropic.com/legal).

Pilothouse is two apps and a shared Swift package:

* **Pilothouse for Mac** — a small menu bar app that starts and supervises the
  official `claude` command-line tool on your Mac, keeps the Mac awake and
  forwards everything to your paired devices.
* **Pilothouse for iPhone & iPad** — start sessions in any project folder,
  follow responses, thinking, tool calls, diffs and terminal output live, and
  approve or deny every action.

Pilothouse **never talks to Anthropic** and never touches your Claude
credentials: your own `claude` CLI does all the AI work, signed in with your own
account. There is no server, no account and no telemetry — only your devices,
end-to-end encrypted.

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

**iPhone / iPad app** — from the App Store (TestFlight during the beta). You can
try everything first with **Try the Demo**: a simulated Mac inside the app, no
Mac or account needed.

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

* **New Chat** → browse the folders in your Mac's home folder (favorites,
  recent folders, Git repositories are marked) → **Start in …**. Choose the
  model and the permission mode:
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
* On the Mac, the menu bar shows running sessions and pending approvals; you can
  answer them there as well.

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
Since 1.1, under Settings → Notifications on the Mac (off by default): native
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
open Pilothouse.xcodeproj          # Xcode 16 or later; schemes PilothouseMac / PilothouseiOS
scripts/test.sh                    # all tests that this machine can run
```

* `PilothouseKit/` — protocol, crypto, client, demo Mac (`PilothouseKit`) and
  the Mac host core (`PilothouseHost`); builds and tests on Linux too
  (`swift test`).
* `PilothouseMac/`, `PilothouseHelper/`, `PilothouseiOS/` — the apps.
* `project.yml` — XcodeGen spec; run `scripts/bootstrap.sh` after changing it.
* Releases: [docs/RELEASE.md](docs/RELEASE.md). Tests:
  [docs/TESTING.md](docs/TESTING.md). Design decisions:
  [docs/DECISIONS.md](docs/DECISIONS.md).

No third-party dependencies on Apple platforms.

## Contributing

Issues and pull requests are welcome — please read
[CONTRIBUTING.md](CONTRIBUTING.md) first. Translations live in
`scripts/l10n/`; adding a language is a great first contribution.

## License

[MIT](LICENSE) © 2026 Arda Şentürk.

"Claude" and "Claude Code" are trademarks of Anthropic, PBC, used here only to
describe compatibility. "Tailscale" is a trademark of Tailscale Inc.
