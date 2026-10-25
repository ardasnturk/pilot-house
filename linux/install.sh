#!/usr/bin/env bash
# Installs or updates Pilothouse on a Raspberry Pi (64-bit Ubuntu / Raspberry
# Pi OS) or any Linux machine with Docker. Safe to run again at any time.
#
#   linux/install.sh            install, or rebuild and restart with the current code
#   linux/install.sh update     git pull, then the same
#   linux/install.sh --no-avahi skip Bonjour (the phone then relies on the IP address)
#
# Afterwards: sign in to Claude once and pair the phone (the script says how).
set -euo pipefail

cd "$(dirname "$0")"
LINUX_DIR="$(pwd)"
REPO_DIR="$(cd .. && pwd)"
COMPOSE=(docker compose -f "$LINUX_DIR/docker-compose.yml")
WITH_AVAHI=true
UPDATE=false
for argument in "$@"; do
  case "$argument" in
    update | --update) UPDATE=true ;;
    --no-avahi) WITH_AVAHI=false ;;
    -h | --help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "Unknown option: $argument" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!! %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31mxx %s\033[0m\n' "$*" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then
  die "Run this as your normal user (e.g. ubuntu), not as root. It uses sudo where needed."
fi
SUDO=sudo
command -v sudo >/dev/null || die "sudo is required."

# --- 1. Machine -------------------------------------------------------------------
say "Checking the machine"
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64 | arm64 | x86_64 | amd64) echo "Architecture: $ARCH" ;;
  armv7l | armv6l) die "A 32-bit system ($ARCH) cannot run Swift. Install a 64-bit OS (Ubuntu Server 24.04 arm64 or Raspberry Pi OS 64-bit)." ;;
  *) die "Unsupported architecture $ARCH." ;;
esac
MEMORY_MB="$(awk '/MemTotal/ { print int($2 / 1024) }' /proc/meminfo)"
echo "Memory: ${MEMORY_MB} MB"
if [ "$MEMORY_MB" -lt 3500 ]; then
  warn "Less than 4 GB of memory: building the image may fail. Add swap (e.g. 4 GB) if it does."
fi
FREE_GB="$(df -Pk "$HOME" | awk 'NR == 2 { print int($4 / 1024 / 1024) }')"
echo "Free disk: ${FREE_GB} GB"
[ "$FREE_GB" -ge 8 ] || warn "Less than 8 GB free: the build needs about 6 GB (Swift toolchain, Node.js, Claude Code)."

if $UPDATE && [ -d "$REPO_DIR/.git" ]; then
  say "Updating the code"
  git -C "$REPO_DIR" pull --ff-only
fi

# --- 2. Docker --------------------------------------------------------------------
say "Docker"
if ! command -v docker >/dev/null; then
  echo "Installing Docker (get.docker.com)…"
  curl -fsSL https://get.docker.com | $SUDO sh
fi
$SUDO systemctl enable --now docker >/dev/null 2>&1 || true
if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
  $SUDO usermod -aG docker "$USER"
  warn "Added $USER to the docker group; it takes effect at the next login. Using sudo for now."
fi
if ! docker info >/dev/null 2>&1; then
  COMPOSE=($SUDO "${COMPOSE[@]}")
  DOCKER=($SUDO docker)
else
  DOCKER=(docker)
fi
if ! "${DOCKER[@]}" compose version >/dev/null 2>&1; then
  echo "Installing the Docker Compose plugin…"
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq docker-compose-plugin || $SUDO apt-get install -y -qq docker-compose-v2
fi
"${DOCKER[@]}" --version
"${DOCKER[@]}" compose version

# --- 3. Settings and folders ------------------------------------------------------------
say "Settings (linux/.env)"
ENV_FILE="$LINUX_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  sed \
    -e "s|^PROJECTS_DIR=.*|PROJECTS_DIR=$HOME/projects|" \
    -e "s|^PILOTHOUSE_HOME=.*|PILOTHOUSE_HOME=$HOME/.pilothouse|" \
    -e "s|^PUID=.*|PUID=$(id -u)|" \
    -e "s|^PGID=.*|PGID=$(id -g)|" \
    "$LINUX_DIR/.env.example" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "Created $ENV_FILE"
else
  echo "Keeping $ENV_FILE"
fi
# The last `KEY=value` line of .env (Compose syntax, so it is not sourced).
env_value() {
  sed -n "s/^[[:space:]]*$1=//p" "$ENV_FILE" | tail -n1 | sed -e 's/^["'\'']//' -e 's/["'\'']$//'
}
PROJECTS_DIR="$(env_value PROJECTS_DIR)"; PROJECTS_DIR="${PROJECTS_DIR:-$HOME/projects}"
PILOTHOUSE_HOME="$(env_value PILOTHOUSE_HOME)"; PILOTHOUSE_HOME="${PILOTHOUSE_HOME:-$HOME/.pilothouse}"
PUID="$(env_value PUID)"; PUID="${PUID:-$(id -u)}"
PGID="$(env_value PGID)"; PGID="${PGID:-$(id -g)}"
mkdir -p "$PROJECTS_DIR" "$PILOTHOUSE_HOME"
if [ "$(stat -c %u "$PILOTHOUSE_HOME")" != "$PUID" ]; then
  $SUDO chown -R "$PUID:$PGID" "$PILOTHOUSE_HOME"
fi
if [ "$(stat -c %u "$PROJECTS_DIR")" != "$PUID" ]; then
  warn "$PROJECTS_DIR does not belong to UID $PUID; Claude may not be able to write there."
fi
echo "Projects: $PROJECTS_DIR"
echo "Data:     $PILOTHOUSE_HOME"

# --- 4. Firewall ------------------------------------------------------------------
if command -v ufw >/dev/null && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
  say "Firewall (ufw)"
  $SUDO ufw allow 47823:47842/tcp comment "Pilothouse" >/dev/null
  echo "Opened 47823-47842/tcp. Dev servers need their ports too, e.g.: sudo ufw allow 8081/tcp (Expo), 5173/tcp (Vite), 3000/tcp (Next.js)."
fi

# --- 5. Build and start -------------------------------------------------------------
say "Building the image (the first build takes 15-40 minutes on a Raspberry Pi)"
"${COMPOSE[@]}" build --pull
say "Starting Pilothouse"
"${COMPOSE[@]}" up -d --remove-orphans

echo -n "Waiting for Pilothouse to start"
for _ in $(seq 1 60); do
  if "${DOCKER[@]}" exec pilothouse pilothouse-server health >/dev/null 2>&1; then
    echo " — running."
    break
  fi
  echo -n "."
  sleep 2
done
"${DOCKER[@]}" exec pilothouse pilothouse-server health >/dev/null 2>&1 \
  || die "Pilothouse did not start. See: ${COMPOSE[*]} logs --tail 100"

# --- 6. Bonjour (optional) -------------------------------------------------------
if $WITH_AVAHI && command -v apt-get >/dev/null; then
  say "Bonjour (Avahi), so the phone finds the Pi even when its address changes"
  if ! command -v avahi-daemon >/dev/null; then
    $SUDO apt-get update -qq && $SUDO apt-get install -y -qq avahi-daemon >/dev/null
  fi
  "${DOCKER[@]}" exec pilothouse pilothouse-server avahi-service | $SUDO tee /etc/avahi/services/pilothouse.service >/dev/null
  $SUDO systemctl enable --now avahi-daemon >/dev/null 2>&1 || true
  $SUDO systemctl reload avahi-daemon >/dev/null 2>&1 || $SUDO systemctl restart avahi-daemon >/dev/null 2>&1 || true
  echo "Published _pilothouse._tcp."
fi

# --- 7. Status and next steps ---------------------------------------------------
say "Status"
"${DOCKER[@]}" exec pilothouse pilothouse-server status || true

cat <<EOF

Next steps:
  1. Sign in to Claude Code once (opens a link to log in, then paste the code back):
       docker exec -it pilothouse claude
     Then type /exit. (Or put CLAUDE_CODE_OAUTH_TOKEN into linux/.env.)
  2. Pair the iPhone or iPad (same Wi-Fi; Pilothouse app → Pair with Your Mac → Scan the Pairing Code):
       docker exec -it pilothouse pilothouse-server pair
  3. On the phone: New Chat → projects → pick or create a folder → ask Claude.

Logs:    ${COMPOSE[*]} logs -f
Update:  $LINUX_DIR/install.sh update
EOF
