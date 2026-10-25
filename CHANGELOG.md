# Changelog

All notable changes to Remote Code are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.2.0] — 2026-10-25

### Changed
- First release as **Remote Code**: new name, new icon (a `>_` prompt with a
  signal), repository `ardasnturk/remote-code` and website
  rcode.ardasnturk.com. Pairings, settings, session logs and the keychain
  identity of earlier versions carry over. The Mac app is `Remote Code.app`
  and the Homebrew cask `remote-code`.

### Added
- "Allow everything in this chat" on the permission sheet, and a Permissions
  picker in the chat's menu: a chat's permission mode can now change at any
  time, even during a reply. "Bypass permissions" still has to be allowed in
  the Mac's settings first.

### Fixed
- "Open Remote Code at login" no longer looks switched off while it is on. The
  switch is read again whenever Settings opens or the app comes to the front,
  counts a login item that waits for approval as on and offers to open Login
  Items for it, and errors now show in Settings instead of the menu.
- The weekly summary is written in the language the iPhone app is shown in,
  not the Mac's, and no longer mixes languages.

[Unreleased]: https://github.com/ardasnturk/remote-code/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/ardasnturk/remote-code/releases/tag/v1.2.0
