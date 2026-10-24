# Homebrew cask for the Pilothouse Mac app.
#
#   brew tap ardasnturk/pilothouse https://github.com/ardasnturk/pilot-house
#   brew install --cask pilothouse
#
# `version` and `sha256` are updated by scripts/prepare-release.sh.
cask "pilothouse" do
  version "1.1.0"
  sha256 "332b30cc1da13c1c4c4d45b303adb4409b283972cf65a22b8bd4a114c094e531"

  url "https://github.com/ardasnturk/pilot-house/releases/download/v#{version}/Pilothouse-#{version}.dmg"
  name "Pilothouse"
  desc "Drive Claude Code, Codex and Gemini CLI on your Mac from iPhone and iPad"
  homepage "https://github.com/ardasnturk/pilot-house"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sequoia"

  app "Pilothouse.app"

  uninstall quit:      "com.ardasenturk.Pilothouse.Mac",
            launchctl: "com.ardasenturk.Pilothouse.Helper"

  zap trash: [
    "~/Library/Application Support/Pilothouse",
    "~/Library/Caches/com.ardasenturk.Pilothouse.Mac",
    "~/Library/HTTPStorages/com.ardasenturk.Pilothouse.Mac",
    "~/Library/Preferences/com.ardasenturk.Pilothouse.Mac.plist",
  ]

  caveats <<~EOS
    Pilothouse needs at least one agent CLI on this Mac, signed in with your
    own account: Claude Code, Codex or Gemini CLI.
      https://docs.claude.com/en/docs/claude-code/setup

    The pairing keys live in your login keychain ("Pilothouse identity key");
    `brew uninstall --zap` does not remove them. Delete them in Keychain Access
    if you want a completely clean uninstall.
  EOS
end
