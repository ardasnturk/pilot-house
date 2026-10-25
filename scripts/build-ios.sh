#!/usr/bin/env bash
# Archives the iOS app and uploads it to App Store Connect / TestFlight.
# It never submits for App Review — that is a manual, deliberate step
# (docs/RELEASE.md).
#
# Requirements: Xcode signed in to team 5JMD3VSD7N, or an App Store Connect
# API key:
#   ASC_KEY_PATH=~/.appstoreconnect/AuthKey_XXXX.p8 ASC_KEY_ID=XXXX ASC_ISSUER_ID=<uuid>
#
#   BUILD_NUMBER=42 scripts/build-ios.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"([^"]+)".*/\1/')}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
ARCHIVE="build/ios/Pilothouse.xcarchive"
AUTH=()
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

rm -rf build/ios && mkdir -p build/ios

echo "▸ Archiving Remote Code $VERSION ($BUILD_NUMBER)"
xcodebuild archive \
  -project Pilothouse.xcodeproj -scheme PilothouseiOS -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

echo "▸ Uploading to App Store Connect (TestFlight)"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist scripts/export/ExportOptions-ios.plist \
  -exportPath build/ios/export \
  -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"}

echo "✔ Uploaded build $BUILD_NUMBER. It appears in TestFlight after processing."
echo "  App Store submission is NOT automatic — review metadata/ios and submit manually."
