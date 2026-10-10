#!/usr/bin/env bash
# Gate: build for a generic iOS device with signing OFF (works with the
# placeholder team, no Apple account, no phone). STRAIT_APP_CLIP=1 includes the App Clip.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
scripts/generate.sh
xcodebuild build -project StraitReference.xcodeproj -scheme StraitReference \
  -configuration "${CONFIGURATION:-Debug}" -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO -quiet
echo "OK: StraitReference builds for generic iOS (signing off, App Clip: ${STRAIT_APP_CLIP:-0})"
