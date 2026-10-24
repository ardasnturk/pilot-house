#!/usr/bin/env bash
# Builds, signs (Developer ID), notarizes and staples Pilothouse for Mac and
# packages it as a DMG for GitHub Releases / Homebrew.
#
# Requirements (see docs/RELEASE.md):
#   * Xcode with a "Developer ID Application" certificate of team 5JMD3VSD7N
#   * notarytool credentials stored once with:
#       xcrun notarytool store-credentials pilothouse-notary \
#         --apple-id <apple-id> --team-id 5JMD3VSD7N --password <app-specific-password>
#     (or set NOTARY_PROFILE to another stored profile)
#
# Output: dist/Pilothouse-<version>.dmg (+ .sha256)
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-pilothouse-notary}"
VERSION="${VERSION:-$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"([^"]+)".*/\1/')}"
BUILD="build/mac"
DIST="dist"
ARCHIVE="$BUILD/Pilothouse.xcarchive"
EXPORT="$BUILD/export"
APP="$EXPORT/Pilothouse.app"
DMG="$DIST/Pilothouse-$VERSION.dmg"

rm -rf "$BUILD" && mkdir -p "$BUILD" "$DIST"

echo "▸ Archiving Pilothouse $VERSION"
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
ditto -c -k --keepParent "$APP" "$BUILD/Pilothouse.zip"
xcrun notarytool submit "$BUILD/Pilothouse.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

echo "▸ Building the DMG"
STAGING="$BUILD/dmg"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Pilothouse" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"
codesign --sign "Developer ID Application" --timestamp "$DMG"

echo "▸ Notarizing the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "✔ $DMG"
echo "Next: scripts/prepare-release.sh $VERSION"
