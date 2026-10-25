#!/usr/bin/env bash
# Builds, signs (Developer ID), notarizes and staples Remote Code for Mac and
# packages it as a DMG for GitHub Releases / Homebrew.
#
# Requirements (see docs/RELEASE.md):
#   * Xcode with a "Developer ID Application" certificate of team 5JMD3VSD7N
#   * dmgbuild for the designed DMG window: `pipx install dmgbuild`
#   * notarytool credentials stored once with:
#       xcrun notarytool store-credentials pilothouse-notary \
#         --apple-id <apple-id> --team-id 5JMD3VSD7N --password <app-specific-password>
#     (or set NOTARY_PROFILE to another stored profile)
#
# Output: dist/RemoteCode-<version>.dmg (+ .sha256), and the bridge image
# dist/Pilothouse-<version>.dmg for copies from before the rename (1.1.x): their
# updater looks for that name and for Pilothouse.app inside it.
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-pilothouse-notary}"
VERSION="${VERSION:-$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"([^"]+)".*/\1/')}"
BUILD="build/mac"
DIST="dist"
ARCHIVE="$BUILD/RemoteCode.xcarchive"
EXPORT="$BUILD/export"
APP="$EXPORT/Remote Code.app"
DMG="$DIST/RemoteCode-$VERSION.dmg"
LEGACY_DMG="$DIST/Pilothouse-$VERSION.dmg"

rm -rf "$BUILD" && mkdir -p "$BUILD" "$DIST"

echo "▸ Archiving Remote Code $VERSION"
xcodebuild archive \
  -project Pilothouse.xcodeproj -scheme PilothouseMac -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  MARKETING_VERSION="$VERSION"

echo "▸ Exporting with Developer ID"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/export/ExportOptions-mac.plist \
  -exportPath "$EXPORT"

echo "▸ Verifying signatures (app + embedded helper)"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --verbose=2 "$APP/Contents/MacOS/PilothouseHelper" 2>&1 | grep -E "Identifier|TeamIdentifier"
test -f "$APP/Contents/Library/LaunchDaemons/com.ardasenturk.Pilothouse.Helper.plist"

echo "▸ Notarizing the app"
ditto -c -k --keepParent "$APP" "$BUILD/RemoteCode.zip"
xcrun notarytool submit "$BUILD/RemoteCode.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

echo "▸ Building the DMG"
rm -f "$DMG"
DMGBUILD="${DMGBUILD:-$(command -v dmgbuild || true)}"
if [[ -n "$DMGBUILD" ]]; then
  # Designed window: background, icon positions (scripts/dmg/settings.py).
  "$DMGBUILD" -s scripts/dmg/settings.py -D app="$APP" "Remote Code" "$DMG"
elif [[ "${ALLOW_PLAIN_DMG:-0}" != "1" ]]; then
  # A release DMG without its designed window is a mistake, not a fallback.
  echo "dmgbuild not found. Install it (pipx install dmgbuild) or point DMGBUILD at it;" >&2
  echo "ALLOW_PLAIN_DMG=1 builds a plain DMG for local testing." >&2
  exit 1
else
  echo "  ALLOW_PLAIN_DMG=1 — building a plain DMG without the designed window"
  STAGING="$BUILD/dmg"
  mkdir -p "$STAGING"
  cp -R "$APP" "$STAGING/"
  ln -s /Applications "$STAGING/Applications"
  hdiutil create -volname "Remote Code" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"
fi
codesign --sign "Developer ID Application" --timestamp "$DMG"

echo "▸ Notarizing the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

shasum -a 256 "$DMG" | tee "$DMG.sha256"

echo "▸ Building the bridge DMG for 1.1.x updaters"
# Same signed app, only the bundle folder is named Pilothouse.app; the next
# update from the new updater installs it as "Remote Code.app".
rm -f "$LEGACY_DMG"
LEGACY="$BUILD/legacy-dmg"
mkdir -p "$LEGACY"
ditto "$APP" "$LEGACY/Pilothouse.app"
ln -s /Applications "$LEGACY/Applications"
hdiutil create -volname "Remote Code" -srcfolder "$LEGACY" -fs HFS+ -format UDZO -ov "$LEGACY_DMG"
codesign --sign "Developer ID Application" --timestamp "$LEGACY_DMG"
xcrun notarytool submit "$LEGACY_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$LEGACY_DMG"
(cd "$DIST" && shasum -a 256 "$(basename "$LEGACY_DMG")") > "$LEGACY_DMG.sha256"

echo "✔ $DMG"
echo "✔ $LEGACY_DMG"
echo "Next: scripts/prepare-release.sh $VERSION"
