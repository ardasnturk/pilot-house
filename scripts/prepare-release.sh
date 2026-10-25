#!/usr/bin/env bash
# Prepares a GitHub Release *draft* for a notarized DMG built by
# scripts/build-mac.sh and updates the Homebrew cask to point at it.
#
#   scripts/prepare-release.sh 1.0.0
#
# What it does:
#   1. checks dist/RemoteCode-<version>.dmg and its .sha256 exist and match
#   2. writes the new version + sha256 into Casks/remote-code.rb
#   3. creates (or updates) a DRAFT release v<version> with the DMG and the
#      notes from docs/release-notes/<version>.md — if the GitHub CLI is
#      available and signed in; otherwise it prints the commands to run
#
# It never publishes the release: review the draft on GitHub and press
# "Publish release" yourself, then commit and push the cask change.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"([^"]+)".*/\1/')}"
TAG="v$VERSION"
DMG="dist/RemoteCode-$VERSION.dmg"
NOTES="docs/release-notes/$VERSION.md"
CASK="Casks/remote-code.rb"

[[ -f "$DMG" ]] || { echo "Missing $DMG — run scripts/build-mac.sh first" >&2; exit 1; }
[[ -f "$NOTES" ]] || { echo "Missing $NOTES — write the release notes first" >&2; exit 1; }

SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
if [[ -f "$DMG.sha256" ]] && ! grep -q "$SHA" "$DMG.sha256"; then
  echo "$DMG.sha256 does not match the DMG — rebuild" >&2
  exit 1
fi
if command -v xcrun >/dev/null && ! xcrun stapler validate "$DMG" >/dev/null 2>&1; then
  echo "$DMG has no stapled notarization ticket — run scripts/build-mac.sh" >&2
  exit 1
fi

ASSETS=("$DMG" "$DMG.sha256")

echo "▸ Updating $CASK → $VERSION ($SHA)"
python3 - "$CASK" "$VERSION" "$SHA" <<'PY'
import re, sys
path, version, sha = sys.argv[1:]
text = open(path, encoding="utf-8").read()
text = re.sub(r'version "[^"]*"', f'version "{version}"', text, count=1)
text = re.sub(r'sha256 (:no_check|"[0-9a-f]*")', f'sha256 "{sha}"', text, count=1)
open(path, "w", encoding="utf-8").write(text)
PY

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  if gh release view "$TAG" >/dev/null 2>&1; then
    echo "▸ Updating the existing release $TAG (stays as it is: draft or published)"
    gh release upload "$TAG" "${ASSETS[@]}" --clobber
    gh release edit "$TAG" --notes-file "$NOTES"
  else
    echo "▸ Creating the draft release $TAG"
    gh release create "$TAG" "${ASSETS[@]}" \
      --draft --title "Remote Code $VERSION" --notes-file "$NOTES"
  fi
  echo "✔ Draft ready. Review it on GitHub, publish it, then:"
else
  echo "GitHub CLI not available or not signed in. Create the draft with:"
  echo "  gh release create $TAG ${ASSETS[*]} --draft --title 'Remote Code $VERSION' --notes-file $NOTES"
  echo "Then, after publishing:"
fi
echo "  git commit -m 'Homebrew cask $VERSION' $CASK && git push"
