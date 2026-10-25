# Pilothouse on a Raspberry Pi (or any Linux machine)

Instead of a Mac, a Raspberry Pi at home can run your agents: `pilothouse-server`
is the Pilothouse host without the Mac app. The **same iPhone and iPad app**
pairs with it, starts chats in any folder, streams every step and asks you
before every edit or command. It runs in a Docker container that also has the
tools for Node.js, Expo and web projects, and it shares the Pi's network, so the
dev servers Claude starts are reachable from your phone.

```
iPhone (Pilothouse app) ──Wi-Fi / Tailscale, Noise-encrypted──▶ Raspberry Pi
                                                                └─ Docker: pilothouse
                                                                   ├─ pilothouse-server :47823
                                                                   ├─ claude (Claude Code), node, git, …
                                                                   └─ ~/projects  (a folder on the Pi)
```

## Requirements

| | |
|---|---|
| Machine | Raspberry Pi 4 or 5 with **4 GB+** (8 GB recommended), or any Linux PC/server |
| OS | A **64-bit** system: Ubuntu Server 22.04/24.04 (arm64) or Raspberry Pi OS 64-bit. 32-bit systems cannot run Swift. |
| Disk | About 8 GB free (the build needs the Swift toolchain once) |
| Claude Code | Your own Claude account (signed in once inside the container) or an API key |
| Phone | Pilothouse for iPhone/iPad ([TestFlight](https://testflight.apple.com/join/6CE4VRRE)) on the same Wi-Fi, or Tailscale |

## Install

On the Pi, as your normal user (not root):

```sh
git clone https://github.com/ardasnturk/pilot-house.git ~/pilot-house
~/pilot-house/linux/install.sh
```

The script is safe to run again. It:

1. checks the architecture, memory and disk,
2. installs Docker and the Compose plugin if they are missing,
3. writes `linux/.env` (your settings; see [`.env.example`](.env.example)) and
   creates `~/projects` and `~/.pilothouse` (the container's home folder),
4. opens port 47823 if `ufw` is active,
5. builds the image (the first build takes 15–40 minutes on a Pi) and starts it,
6. publishes the host over Bonjour with Avahi, so the phone finds the Pi even
   after its address changed (`--no-avahi` skips this),
7. prints the status and the next steps.

Then, once:

```sh
docker exec -it pilothouse claude          # sign in to Claude Code, then /exit
docker exec -it pilothouse pilothouse-server pair
```

`claude` shows a link: open it on any device, log in, and paste the code back.
`pair` shows a QR code in the terminal. In the app, tap **Pair with Your Mac →
Scan the Pairing Code** (or paste the link it prints under **Paste a Pairing
Link Instead**). Both screens show the same verification code, and the terminal
confirms when the phone is paired.

Instead of signing in interactively, you can create a long-lived token with
`claude setup-token` on any computer and put it into `linux/.env` as
`CLAUDE_CODE_OAUTH_TOKEN=…`. `ANTHROPIC_API_KEY=…` works too.

## Use

In the app: **New Chat → projects** → pick a folder or create one → ask, for
example *"Create an Expo app with a counter and start it so I can open it in
Expo Go"*. The phone shows "Mac" in a few places; that is the Pi.

* **Projects** are in `~/projects` on the Pi, inside the container
  `/home/pilot/projects`. The phone can only browse the container's home folder.
* **Web apps:** Claude knows (from `~/.claude/CLAUDE.md`, written by the
  container) to bind dev servers to `0.0.0.0` and to give you the URL with the
  Pi's address, e.g. `http://192.168.1.50:5173`.
* **Expo:** `npx expo start --lan`; open `exp://<Pi address>:8081` in Expo Go.
  `REACT_NATIVE_PACKAGER_HOSTNAME` is already set to the Pi's address. iOS
  builds cannot run on Linux: use Expo Go or EAS Build (`npx eas-cli build`).
* **Permissions** work as on the Mac: every edit and command is sent to the
  phone. To offer *Bypass permissions*, set
  `PILOTHOUSE_ALLOW_BYPASS_PERMISSIONS=true` in `linux/.env`.
* **Notifications:** set `PILOTHOUSE_NTFY_SERVER` and `PILOTHOUSE_NTFY_TOPIC`
  and subscribe to the topic in the ntfy app.
* **Codex / Gemini:** set `INSTALL_CODEX=true` / `INSTALL_GEMINI=true`, run
  `linux/install.sh` again and sign in with `docker exec -it pilothouse codex`.
* **More tools:** Claude may use `sudo apt-get install` inside the container
  (`ALLOW_SUDO`), but packages installed that way are gone after an update.
  For lasting ones, list them in `EXTRA_APT_PACKAGES` and run the script again.
  Global npm packages (`npm install -g`) stay until the next image rebuild.

## Commands

```sh
docker exec -it pilothouse pilothouse-server pair      # pair a phone (QR code)
docker exec pilothouse pilothouse-server status        # addresses, agents, devices, chats
docker exec pilothouse pilothouse-server devices       # paired devices
docker exec pilothouse pilothouse-server revoke ID     # remove one
docker compose -f linux/docker-compose.yml logs -f     # logs
docker compose -f linux/docker-compose.yml restart     # restart (after editing .env)
~/pilot-house/linux/install.sh update                  # git pull, rebuild, restart
```

## Away from home

Install [Tailscale](https://tailscale.com/download/linux) on the Pi
(`curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up`) and on
the phone, pair again (or wait: the phone learns the new address on its next
connection), and turn on **Use Tailscale when away** in the app's settings. The
server finds the Pi's Tailscale address by itself; set
`PILOTHOUSE_MAGICDNS_NAME` if you use MagicDNS.

## Troubleshooting

**The phone cannot connect.** Run `pilothouse-server status`: the addresses
must be the Pi's LAN address (not `172.x` from Docker). If they are wrong, set
`PILOTHOUSE_ADDRESSES=192.168.1.50` in `linux/.env`, restart and pair again. A
fixed address for the Pi in your router (DHCP reservation) avoids surprises.
Guest Wi-Fi networks often keep devices apart. Check `sudo ufw status`.

**"Claude Code is not signed in".** `docker exec -it pilothouse claude`, sign in,
`/exit`. The phone sees it within a minute.

**The build stops with "Killed".** Not enough memory: add swap
(`sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile`)
and run the script again.

**Files in `~/projects` belong to the wrong user.** `PUID`/`PGID` in
`linux/.env` must be your user's `id -u` / `id -g`; change them and run the
script again.

## How it works

`pilothouse-server` (Swift, `PilothouseKit/Sources/PilothouseServer`) reuses the
Mac's host core, `PilothouseHost`: sessions, the permission broker, the event
log, pairing and the Noise-encrypted protocol, unchanged. Only the Mac-specific
parts are replaced: a BSD-socket WebSocket listener instead of
Network.framework, a key file (`~/.local/share/pilothouse/identity.key`,
mode 0600) instead of the Keychain, and settings from environment variables
instead of the menu bar app. The `pair`, `status` and `devices` commands talk to
the running server over `127.0.0.1` with a token stored in
`~/.local/share/pilothouse/control.json`. See
[docs/DECISIONS.md](../docs/DECISIONS.md) D-110.

Without Docker: build with `swift build -c release --product pilothouse-server`
in `PilothouseKit/` (Swift 6.1+), install Claude Code and run the binary as a
systemd service. All settings are the same environment variables.
