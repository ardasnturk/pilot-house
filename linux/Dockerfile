# Pilothouse for Linux: the host (`pilothouse-server`) plus Claude Code and the
# tools it needs to build Node, Expo and web projects. Built natively on the
# Raspberry Pi (linux/arm64) or any linux/amd64 machine. See linux/README.md.
#
#   docker compose -f linux/docker-compose.yml up -d --build

ARG SWIFT_IMAGE=swift:6.1-noble
ARG BASE_IMAGE=ubuntu:24.04

# ---- 1. Build pilothouse-server ---------------------------------------------
FROM ${SWIFT_IMAGE} AS build
WORKDIR /src
COPY PilothouseKit/Package.swift PilothouseKit/
# Resolve swift-crypto first so source changes keep this layer cached.
RUN cd PilothouseKit && swift package resolve
COPY PilothouseKit PilothouseKit
RUN cd PilothouseKit \
    && swift build -c release --static-swift-stdlib --product pilothouse-server \
    && install -D -m 0755 "$(swift build -c release --show-bin-path)/pilothouse-server" /out/pilothouse-server

# ---- 2. Runtime ---------------------------------------------------------------
FROM ${BASE_IMAGE}
ARG NODE_MAJOR=22
# UID/GID of the user on the Pi who owns the projects folder (`id -u`, `id -g`).
ARG PUID=1000
ARG PGID=1000
# Lets Claude `sudo apt-get install` what a project needs (lost on rebuild:
# add lasting packages to EXTRA_APT_PACKAGES instead).
ARG ALLOW_SUDO=true
ARG EXTRA_APT_PACKAGES=""
# Install Codex and Gemini CLI too (sign in once with `docker exec -it pilothouse codex`).
ARG INSTALL_CODEX=false
ARG INSTALL_GEMINI=false

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg git openssh-client \
        bash less nano vim-tiny jq ripgrep fd-find tree unzip zip xz-utils file procps psmisc lsof \
        iproute2 iputils-ping dnsutils netcat-openbsd \
        build-essential pkg-config python3 python3-pip python3-venv \
        libcurl4t64 libxml2 tzdata qrencode sudo \
        ${EXTRA_APT_PACKAGES} \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd

# Node.js from nodejs.org (the newest release of NODE_MAJOR), checksum-verified.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN case "$(dpkg --print-architecture)" in \
        amd64) node_arch=x64 ;; \
        arm64) node_arch=arm64 ;; \
        *) echo "Unsupported architecture $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac \
    && base="https://nodejs.org/dist/latest-v${NODE_MAJOR}.x" \
    && curl -fsSL "$base/SHASUMS256.txt" -o /tmp/SHASUMS256.txt \
    && file="$(awk -v suffix="linux-${node_arch}.tar.xz" 'substr($2, length($2) - length(suffix) + 1) == suffix { print $2 }' /tmp/SHASUMS256.txt)" \
    && curl -fsSL "$base/$file" -o "/tmp/$file" \
    && (cd /tmp && grep " $file\$" SHASUMS256.txt | sha256sum -c -) \
    && tar -xJf "/tmp/$file" -C /usr/local --strip-components=1 --no-same-owner --exclude='*/CHANGELOG.md' --exclude='*/README.md' --exclude='*/LICENSE' \
    && rm -f "/tmp/$file" /tmp/SHASUMS256.txt \
    && node --version && npm --version

# The image's own `ubuntu` user has UID 1000; make room for the Pi's user.
RUN (userdel -r ubuntu 2>/dev/null || true) \
    && (getent group "${PGID}" >/dev/null || groupadd -g "${PGID}" pilot) \
    && useradd -m -u "${PUID}" -g "${PGID}" -s /bin/bash pilot \
    && if [ "${ALLOW_SUDO}" = "true" ]; then echo "pilot ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/pilot && chmod 0440 /etc/sudoers.d/pilot; fi \
    && mkdir -p /opt/npm-global && chown -R "${PUID}:${PGID}" /opt/npm-global

# Global npm packages belong to `pilot`, so Claude Code can update itself and
# `npm install -g` works without root.
ENV NPM_CONFIG_PREFIX=/opt/npm-global \
    PATH=/opt/npm-global/bin:/home/pilot/.local/bin:$PATH \
    SHELL=/bin/bash \
    PILOTHOUSE_LOG=1

USER pilot
RUN npm install -g @anthropic-ai/claude-code \
    && if [ "${INSTALL_CODEX}" = "true" ]; then npm install -g @openai/codex; fi \
    && if [ "${INSTALL_GEMINI}" = "true" ]; then npm install -g @google/gemini-cli; fi \
    && corepack enable --install-directory /opt/npm-global/bin \
    && npm cache clean --force \
    && claude --version

USER root
COPY --from=build /out/pilothouse-server /usr/local/bin/pilothouse-server
COPY linux/entrypoint.sh /usr/local/bin/pilothouse-entrypoint
COPY linux/claude-memory.md /opt/pilothouse/CLAUDE.md
RUN chmod 0755 /usr/local/bin/pilothouse-entrypoint && pilothouse-server version

USER pilot
WORKDIR /home/pilot
EXPOSE 47823
HEALTHCHECK --interval=60s --timeout=10s --start-period=60s --retries=3 \
    CMD pilothouse-server health >/dev/null || exit 1
ENTRYPOINT ["/usr/local/bin/pilothouse-entrypoint"]
CMD ["serve"]
