#!/usr/bin/env bash
# Regenerates Pilothouse.xcodeproj from project.yml (XcodeGen) and the
# generated assets. Run after editing project.yml, icons or translations.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null; then
  echo "XcodeGen is required: brew install xcodegen" >&2
  exit 1
fi
python3 scripts/l10n/ios_translations.py
python3 scripts/l10n/mac_translations.py
python3 scripts/l10n/build_catalogs.py
python3 scripts/l10n/infoplist.py
if python3 -c "import PIL" 2>/dev/null; then
  python3 scripts/generate-icons.py
fi
xcodegen generate --spec project.yml
echo "Open Pilothouse.xcodeproj"
