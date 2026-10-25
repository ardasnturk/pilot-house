#!/usr/bin/env bash
# Prepares the home folder (a volume on the Pi) and starts pilothouse-server.
set -euo pipefail

home="${HOME:-/home/pilot}"
mkdir -p "$home/projects" "$home/.claude" "$home/.local/share/pilothouse"
chmod 700 "$home/.local/share/pilothouse"

# The Pi's LAN address, for dev servers the phone should open (Expo, Vite, …).
if [ -z "${PILOTHOUSE_LAN_IP:-}" ]; then
  addresses="${PILOTHOUSE_ADDRESSES:-}"
  PILOTHOUSE_LAN_IP="${addresses%%[, ]*}"
fi
if [ -z "${PILOTHOUSE_LAN_IP:-}" ]; then
  PILOTHOUSE_LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1 || true)"
fi
export PILOTHOUSE_LAN_IP
# Expo prints this address in its QR code instead of a container address.
export REACT_NATIVE_PACKAGER_HOSTNAME="${REACT_NATIVE_PACKAGER_HOSTNAME:-$PILOTHOUSE_LAN_IP}"

# What Claude should know about this machine (kept if you edited it).
memory="$home/.claude/CLAUDE.md"
if [ ! -f "$memory" ] || grep -q "pilothouse-managed" "$memory"; then
  cp /opt/pilothouse/CLAUDE.md "$memory"
fi

# A git identity, so commits work before you set your own.
if ! git config --global user.name >/dev/null 2>&1; then
  git config --global user.name "${GIT_AUTHOR_NAME:-Pilothouse on $(hostname)}"
  git config --global user.email "${GIT_AUTHOR_EMAIL:-pilot@$(hostname).local}"
fi
git config --global init.defaultBranch main 2>/dev/null || true

if [ "${1:-serve}" = "serve" ]; then
  exec pilothouse-server "$@"
fi
exec "$@"
