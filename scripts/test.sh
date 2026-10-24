#!/usr/bin/env bash
# Runs every automated test that the current machine supports.
#
#   scripts/test.sh            # package tests (+ Xcode tests on macOS)
#   scripts/test.sh --package  # PilothouseKit only (swift test)
#   scripts/test.sh --e2e      # also the real-Claude end-to-end test (needs a signed-in `claude`)
#
# On macOS the Xcode tests run with `xcodebuild test` (no signing needed):
#   * PilothouseMac scheme  → PilothouseKitTests + PilothouseHostTests on macOS
#   * PilothouseiOS scheme  → PilothouseUITests + PilothouseKitTests on an iPhone simulator
set -euo pipefail
cd "$(dirname "$0")/.."

PACKAGE_ONLY=0
E2E=0
for argument in "$@"; do
  case "$argument" in
    --package) PACKAGE_ONLY=1 ;;
    --e2e) E2E=1 ;;
  esac
done

echo "▸ Localisation catalogs"
python3 scripts/l10n/build_catalogs.py --check

echo "▸ App Store metadata"
python3 scripts/check-metadata.py > /dev/null

echo "▸ PilothouseKit (swift test)"
if [[ $E2E -eq 1 ]]; then
  export PILOTHOUSE_E2E_CLAUDE="${PILOTHOUSE_E2E_CLAUDE:-$(command -v claude)}"
fi
(cd PilothouseKit && swift test)

if [[ $PACKAGE_ONLY -eq 1 || "$(uname)" != "Darwin" ]]; then
  exit 0
fi

mkdir -p build/test-results

echo "▸ Mac scheme (xcodebuild test)"
xcodebuild test \
  -project Pilothouse.xcodeproj -scheme PilothouseMac \
  -destination 'platform=macOS' \
  -resultBundlePath build/test-results/mac.xcresult \
  CODE_SIGNING_ALLOWED=NO

SIMULATOR=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime in sorted(devices, reverse=True):
    if "iOS" not in runtime:
        continue
    for device in devices[runtime]:
        if device["name"].startswith("iPhone"):
            print(device["udid"]); sys.exit(0)
sys.exit(1)')

echo "▸ iOS scheme on simulator $SIMULATOR (xcodebuild test)"
xcodebuild test \
  -project Pilothouse.xcodeproj -scheme PilothouseiOS \
  -destination "id=$SIMULATOR" \
  -resultBundlePath build/test-results/ios.xcresult \
  CODE_SIGNING_ALLOWED=NO
