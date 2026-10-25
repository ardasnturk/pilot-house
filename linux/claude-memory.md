<!-- pilothouse-managed: replaced on every start. Delete this line to keep your own edits. -->
# This machine

You run on a **Raspberry Pi** (Linux, arm64, Ubuntu) inside the Pilothouse
Docker container, as the user `pilot`. The person drives you from their
**iPhone or iPad** through the Pilothouse app: they see your messages, diffs and
command output, but **not** a terminal, a desktop or a browser on this machine.

* **Projects** live in `~/projects` (a folder on the Pi, kept across restarts).
  Create new projects there unless asked otherwise.
* **Tools:** Node.js 22 with npm, `npx`, pnpm and yarn (corepack), git,
  Python 3 (`python3 -m venv`), build-essential, ripgrep, jq. Global npm
  packages install without root (`npm install -g …`). `sudo apt-get install`
  works when the image allows it, but such packages are gone after an image
  rebuild — say so when you rely on one.
* **No Docker, no GUI, no simulators** here. iOS apps cannot be built locally:
  for Expo use Expo Go on the phone, or EAS Build (`npx eas-cli build`) in the cloud.

## Dev servers the phone should open

The container shares the Pi's network, so a server bound to `0.0.0.0` is
reachable from the phone at the Pi's LAN address, which is in
`$PILOTHOUSE_LAN_IP` (or run `hostname -I`).

* Always bind to all interfaces: Vite `--host 0.0.0.0`, Next.js `-H 0.0.0.0`,
  Astro `--host`, `python3 -m http.server --bind 0.0.0.0`, Create React App
  `HOST=0.0.0.0`.
* **Expo:** `npx expo start --lan` (with `--tunnel` only if the phone is not on
  the same network). `REACT_NATIVE_PACKAGER_HOSTNAME` is already set to the Pi's
  address; the person opens `exp://$PILOTHOUSE_LAN_IP:8081` in Expo Go.
* Start long-running servers **in the background** so your turn can finish,
  with a log file, for example
  `nohup npm run dev -- --host 0.0.0.0 > /tmp/dev.log 2>&1 &`,
  then check the log and give the person the full URL
  (`http://<PILOTHOUSE_LAN_IP>:<port>`). Stop servers you no longer need
  (`pkill -f vite`), the Pi has limited memory.
* Builds and `npm install` are slower than on a laptop; prefer one package
  manager per project and avoid reinstalling `node_modules` needlessly.
