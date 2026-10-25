#!/usr/bin/env bash
# Captures App Store screenshots with the UI test `ScreenshotTests` on the
# demo Mac: iPhone + iPad × light + dark × EN/TR/DE.
# Output: screenshots/<language>/<device>-<appearance>/<NN-Name>.png
#
# Simulators: the newest installed "iPhone … Pro Max" (6.9") and
# "iPad Pro 13-inch" by default. Override with e.g.
#   IPHONE="iPhone 16 Pro Max" IPAD="iPad Pro 13-inch (M4)" LANGUAGES="en" scripts/screenshots.sh
set -euo pipefail
cd "$(dirname "$0")/.."

read -r -a LANGUAGES <<< "${LANGUAGES:-en tr de}"
APPEARANCES=(light dark)
OUT="screenshots"
WORK="build/screenshots"
rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"

# Prints "<udid>\t<name>" of the newest available simulator whose name equals
# $1 or, when $1 is empty, matches the regular expression $2.
find_simulator() {
  xcrun simctl list devices available -j | python3 -c '
import json, re, sys
exact, pattern = sys.argv[1], sys.argv[2]
devices = json.load(sys.stdin)["devices"]
for runtime in sorted(devices, reverse=True):
    if "iOS" not in runtime:
        continue
    for device in sorted(devices[runtime], key=lambda d: d["name"], reverse=True):
        if (exact and device["name"] == exact) or (not exact and re.fullmatch(pattern, device["name"])):
            print(device["udid"] + "\t" + device["name"]); sys.exit(0)
sys.exit(1)' "$1" "$2"
}

SIMULATORS=()
SIMULATORS+=("$(find_simulator "${IPHONE:-}" 'iPhone \d+ Pro Max')") || { echo "No iPhone Pro Max simulator installed" >&2; exit 1; }
SIMULATORS+=("$(find_simulator "${IPAD:-}" 'iPad Pro 13-inch.*')") || { echo "No 13-inch iPad Pro simulator installed" >&2; exit 1; }

echo "▸ Building for testing"
xcodebuild build-for-testing \
  -project RemoteCode.xcodeproj -scheme RemoteCodeiOS \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$WORK/DerivedData" \
  CODE_SIGNING_ALLOWED=NO > "$WORK/build.log" 2>&1 || { tail -50 "$WORK/build.log"; exit 1; }

for entry in "${SIMULATORS[@]}"; do
  udid="${entry%%$'\t'*}"
  device="${entry#*$'\t'}"
  slug="$(echo "$device" | tr ' ()' '-__' | tr -s '_-')"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b > /dev/null
  xcrun simctl status_bar "$udid" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
  for appearance in "${APPEARANCES[@]}"; do
    xcrun simctl ui "$udid" appearance "$appearance"
    for language in "${LANGUAGES[@]}"; do
      name="$slug-$appearance-$language"
      result="$WORK/$name.xcresult"
      echo "▸ $device · $appearance · $language"
      TEST_RUNNER_SCREENSHOT_LANGUAGE="$language" xcodebuild test-without-building \
        -project RemoteCode.xcodeproj -scheme RemoteCodeiOS \
        -destination "id=$udid" \
        -derivedDataPath "$WORK/DerivedData" \
        -only-testing:RemoteCodeUITests/ScreenshotTests \
        -resultBundlePath "$result" > "$WORK/$name.log" 2>&1 || echo "  (test reported a failure, see $WORK/$name.log)"
      target="$OUT/$language/$slug-$appearance"
      mkdir -p "$target"
      xcrun xcresulttool export attachments --path "$result" --output-path "$target" > /dev/null
      # Name files after the attachment names (01-Sessions.png, …).
      python3 - "$target" <<'PY'
import json, os, shutil, sys
target = sys.argv[1]
manifest = os.path.join(target, "manifest.json")
if os.path.exists(manifest):
    for test in json.load(open(manifest)):
        for attachment in test.get("attachments", []):
            source = os.path.join(target, attachment["exportedFileName"])
            name = attachment.get("suggestedHumanReadableName", attachment["exportedFileName"])
            base = name.split("_")[0]
            if os.path.exists(source):
                shutil.move(source, os.path.join(target, f"{base}.png"))
    os.remove(manifest)
PY
      echo "  $(ls "$target" | wc -l | tr -d ' ') screenshots"
    done
  done
  xcrun simctl status_bar "$udid" clear
done
echo "✔ Screenshots in $OUT/"
