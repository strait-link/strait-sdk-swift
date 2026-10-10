#!/usr/bin/env bash
# Archive the reference app and send it to TestFlight with the Apple account
# signed in to Xcode (Xcode -> Settings -> Accounts). No API key, no password here.
#
#   scripts/testflight.sh            # archive + upload to App Store Connect
#   scripts/testflight.sh --export   # archive + export an .ipa only (no upload)
#   STRAIT_APP_CLIP=1 scripts/testflight.sh   # include the App Clip (beta)
#
# Before the first upload the founder creates the app record in App Store
# Connect for the bundle ID in Config/Team.xcconfig (see IOS-READY.md).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
destination=upload
[[ "${1:-}" == "--export" ]] && destination=export

team="$(sed -n 's/^DEVELOPMENT_TEAM = //p' Config/Team.xcconfig)"
[[ -n "$team" ]] || { echo "No team yet: run scripts/set-team.sh first." >&2; exit 2; }
[[ "$team" != "FV443M4362" ]] || { echo "Refusing the employer's team." >&2; exit 2; }
grep -q '^STRAIT_PUBLISHABLE_KEY *= *st_pub_' Config/Local.xcconfig 2>/dev/null \
  || { echo "Config/Local.xcconfig needs STRAIT_PUBLISHABLE_KEY = st_pub_… (TestFlight builds have no launch env)." >&2; exit 2; }

build="$(date +%Y%m%d%H%M)"   # always increasing, so every upload is accepted
archive="build/StraitReference-$build.xcarchive"
scripts/generate.sh
xcodebuild archive -project StraitReference.xcodeproj -scheme StraitReference -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$build" -quiet

opts="build/ExportOptions.plist"
cat > "$opts" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$destination</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>testFlightInternalTestingOnly</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PL
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$opts" \
  -exportPath "build/export-$build" -allowProvisioningUpdates
if [[ "$destination" == upload ]]; then
  echo "Uploaded build $build. It appears in App Store Connect -> TestFlight after processing (5-30 min)."
else
  echo "Exported: build/export-$build"
fi
