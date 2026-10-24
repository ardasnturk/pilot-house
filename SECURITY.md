# Security policy

Pilothouse lets a phone drive a program that can edit files and run commands on
a Mac, so security reports are taken seriously and handled first.

## Reporting a vulnerability

**Please do not open a public issue.** Report it privately through
[GitHub Security Advisories](https://github.com/ardasnturk/pilot-house/security/advisories/new)
(Security → Report a vulnerability). Include:

* what an attacker can do and under which conditions (same network, paired
  device, local user, …),
* steps to reproduce or a proof of concept,
* the Pilothouse versions (Mac and iPhone/iPad) and macOS/iOS versions.

You will get an answer within 7 days. Fixes for confirmed issues are released
as soon as possible, and you are credited in the release notes unless you
prefer otherwise.

## Supported versions

| Version | Supported |
|---|---|
| 1.0.x | ✅ |

## Scope

In scope: the pairing flow and handshake, the encrypted channel, the
home-folder sandbox, permission forwarding (MCP endpoint), the privileged
helper, local storage of keys and logs, and the notification and agent
integrations.

Out of scope: vulnerabilities in Claude Code, Codex, Gemini CLI or Tailscale
themselves (report those to their vendors), and attacks that need an unlocked,
already paired device.

The threat model and mitigations are described in
[docs/SECURITY.md](docs/SECURITY.md).
