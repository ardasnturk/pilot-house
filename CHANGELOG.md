# Changelog

All notable changes to Remote Code (called Pilothouse up to 1.1.2) are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- Pilothouse is now **Remote Code**: new name, new icon (a `>_` prompt with a
  signal) and a new repository, `ardasnturk/remote-code`. Pairings, settings,
  session logs and the keychain identity carry over: the bundle identifiers,
  the pairing protocol and the data folder keep their old names. The Mac app
  is now `Remote Code.app`; copies from before the rename update to it through
  a bridge image (`Pilothouse-<version>.dmg`), and the Homebrew cask is now
  `remote-code`.

### Fixed
- "Open Remote Code at login" no longer looks switched off while it is on. The
  switch is read again whenever Settings opens or the app comes to the front,
  counts a login item that waits for approval as on and offers to open Login
  Items for it, and errors now show in Settings instead of the menu.

## [1.1.2] — 2026-10-25

### Added
- "Allow everything in this chat" on the permission sheet, and a Permissions
  picker in the chat's menu: a chat's permission mode can now change at any
  time, even during a reply. "Bypass permissions" still has to be allowed in
  the Mac's settings first.

### Fixed
- The weekly summary is written in the language the iPhone app is shown in.
  It used the Mac's language, and the on-device model sometimes switched to
  the language of the chats, so one summary could mix several languages.
  The phone now sends its language with the request (needs the new Mac app
  and the new iPhone app); a cached summary in another language is rebuilt.

## [1.1.1] — 2026-10-24

### Fixed
- iPhone and iPad connect to the Mac over Wi-Fi again: iOS aborted the system
  WebSocket connections to local addresses right after connecting, so only
  Tailscale worked. The app now speaks WebSocket over a plain TCP connection.
- The pairing screen shows the technical reason per address when the Mac
  cannot be reached.
- With "Use Tailscale when away" on, the app says when it does not know the
  Mac's Tailscale address yet (connect once over the same Wi-Fi to learn it).
- The DMG opens with its designed window again.

## [1.1.0] — 2026-10-24

### Mac
- New look: a gradient header with the status, cards for what needs you now,
  and a simpler menu; addresses, devices, agents and Tailscale moved to
  Settings.
- Settings redesigned as a sidebar of panes (General, iPhone & iPad, Agents,
  Notifications, Remote Access, Updates, Security).
- Updates from inside the app: a daily check on GitHub and **Install and
  Relaunch**, with checksum, notarization and signature checks.
- A redesigned DMG window.
- Model lists and effort levels are read from Claude Code and Codex
  themselves.

### iPhone and iPad
- New look with the brand gradient, glass cards and a connection card that
  says what to do when the Mac is not reachable.
- Tool calls and thinking open in sheets; the chat reads like the Claude and
  Codex apps.
- While the agent works, its status, current step and a timer show inside the
  message field; Send turns into Stop.
- Attach photos, videos (sent as frames) and camera shots.
- Models and effort levels as the CLIs report them, with their real names.
- Ten languages: English, Turkish, German, Spanish, French, Italian,
  Brazilian Portuguese, Japanese, Korean and Simplified Chinese.
- Clearer welcome screen and settings.

### Connection
- The local network always comes first; Tailscale is only used when you turn
  on "Use Tailscale when away".

## [1.0.1] — 2026-10-24

### Fixed
- iPhone and iPad connect to the Mac on the same Wi-Fi without Tailscale: the
  app now waits for the Local Network permission instead of giving up, and
  says so with a Settings button when the permission is off.
- The `/` list of skills and commands is filled for new chats too, before the
  first message (read from the project, `~/.claude` and enabled plugins).

### Added
- Effort level per chat (Claude Code: low to max; Codex: low to extra high),
  with a default for new chats in Settings.
- Change a chat's model and effort from the model chip in the composer or the
  session menu; it applies from the next message.
- A `/` button in the composer opens the list of skills and commands.
- Mac: a "Get the iPhone App" window with the TestFlight QR code, shown on
  first launch and from the menu.

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

[Unreleased]: https://github.com/ardasnturk/remote-code/compare/v1.1.1...HEAD
[1.1.1]: https://github.com/ardasnturk/remote-code/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/ardasnturk/remote-code/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/ardasnturk/remote-code/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/ardasnturk/remote-code/releases/tag/v1.0.0
