# Changelog

All notable changes to Pilothouse are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] — 2026-10-24

The first public release: a Mac menu bar app and an iPhone/iPad app to drive
coding-agent CLIs on your Mac.

### Mac
- Starts and supervises Claude Code, Codex (`codex app-server`) and Gemini CLI
  (`gemini --experimental-acp`) in any folder of your home folder; finds which
  ones are installed and signed in (Settings → Agents).
- Pairing by QR code, Noise IK end-to-end encryption with pinned keys, instant
  revocation of devices; Bonjour on the local network and Tailscale elsewhere,
  with a guided Tailscale setup.
- Keeps the Mac awake; optional lid-closed mode through a small privileged
  helper.
- Claude can delegate tasks to Codex or Gemini with a `delegate_to_agent` tool;
  every delegation and every action of the sub-agent needs your approval.
- Weekly summary per project and day, written on the Mac by Apple Intelligence
  (macOS 26) and shown on the phone; usage limits of Claude and Codex with
  reset times, also in the menu.
- Notifications on the Mac and, through ntfy, on your phone when a task
  finishes, needs approval, a sub-agent finishes or a session fails.
- Notarized DMG and a Homebrew cask.

### iPhone and iPad
- New Chat in three steps: where (browse folders, create a new one), who
  (Claude Code, Codex, Gemini) and how (model, permission mode).
- Live transcript with thinking, tool cards, diffs and terminal output;
  approve, deny or always allow; Stop; continue closed sessions.
- Sub-agents in their own window, with running ones shown above the composer.
- `/` opens a searchable list of the session's skills and slash commands, with
  descriptions and their source (personal, project, plugin, built-in).
- "This week" card and Insights: weekly chart, project cards, the written
  summary and a Limits tab.
- Demo mode with a simulated Mac; English, Turkish and German.

### Fixed during the release
- The Mac menu panel collapsed to its header on macOS 27.
- Diff statistics counted `---`/`+++` file headers as changed lines.

[Unreleased]: https://github.com/ardasnturk/pilot-house/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/ardasnturk/pilot-house/releases/tag/v1.0.0
