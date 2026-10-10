#!/usr/bin/env bash
# Point the reference app at a real Apple team, in one step:
#   scripts/set-team.sh <TEAM_ID> <BUNDLE_PREFIX> [<link host>]
#   e.g. scripts/set-team.sh ABCDE12345 in.straitlink strait-dev.strait.link
#
# Updates Config/Team.xcconfig (team, bundle prefix, link host), regenerates the
# Xcode project, and writes WORKSPACE.md: the exact Strait workspace settings
# (Dashboard -> Settings -> App configuration) and the AASA the engine must serve.
# It also refreshes the values block in README.md. Run it again any time.
set -euo pipefail
cd "$(dirname "$0")/.."
team="${1:-}"; prefix="${2:-}"; host="${3:-}"
if [[ -z "$team" || -z "$prefix" ]]; then
  echo "usage: scripts/set-team.sh <TEAM_ID> <BUNDLE_PREFIX> [<link host>]" >&2; exit 64
fi
team="$(printf '%s' "$team" | tr '[:lower:]' '[:upper:]')"
[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || { echo "Team ID must be 10 letters/digits (developer.apple.com -> Account -> Membership details)" >&2; exit 65; }
[[ "$prefix" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || { echo "Bundle prefix must be reverse-DNS, e.g. in.straitlink" >&2; exit 65; }
if [[ "$team" == "FV443M4362" ]]; then
  echo "Refusing FV443M4362: that is the employer's team, never sign Strait with it." >&2; exit 65
fi
if [[ -z "$host" ]]; then host="$(sed -n 's/^STRAIT_LINK_HOST = //p' Config/Team.xcconfig)"; fi
[[ "$host" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || { echo "Link host must be a bare host like strait-dev.strait.link" >&2; exit 65; }

app="$prefix.reference"; clip="$app.Clip"; group="group.$app"
cat > Config/Team.xcconfig <<XC
// Written by scripts/set-team.sh. Do not edit by hand: run
//   scripts/set-team.sh <TEAM_ID> <BUNDLE_PREFIX> [<link host>]
//
// DEVELOPMENT_TEAM empty = the placeholder team: the project still builds for
// a device with signing off (scripts/build-device.sh), it just can't install.
DEVELOPMENT_TEAM = $team
// App = \$(BUNDLE_PREFIX).reference, App Clip = \$(BUNDLE_PREFIX).reference.Clip
BUNDLE_PREFIX = $prefix
// The Strait workspace link host the app claims (applinks:/appclips:).
STRAIT_LINK_HOST = $host
XC

cat > WORKSPACE.md <<MD
# Strait workspace settings for this build (written by set-team.sh)

| | |
|---|---|
| Apple Team ID | \`$team\` |
| App bundle ID | \`$app\` |
| App Clip bundle ID (beta) | \`$clip\` |
| App Group | \`$group\` |
| Link host (associated domain) | \`$host\` |
| URL scheme | \`straitref://\` |

## 1. Dashboard -> Settings -> App configuration (workspace on \`$host\`)

- Apple Team ID: \`$team\`
- Bundle ID: \`$app\`
- App Store ID: the reference app's Apple ID from App Store Connect (App Information), once the app record exists
- App Clip bundle ID (shown after migration 0062 is applied, only for the App Clip run): \`$clip\`

Save. The engine serves the new file within its 10-minute cache.

## 2. Check what the engine serves

\`\`\`
curl -sS -D - https://$host/.well-known/apple-app-site-association -o /tmp/aasa.json
python3 -m json.tool /tmp/aasa.json
\`\`\`

Expected: \`HTTP 200\`, \`content-type: application/json\`, no \`location\` header, and

\`\`\`json
{"applinks":{"apps":[],"details":[{"appIDs":["$team.$app"],"components":[{"/":"/","exclude":true}, "...Strait paths excluded...", {"/":"/*","comment":"Every Strait link on this host"}],"appID":"$team.$app","paths":["NOT /", "...", "*"]}]}}
\`\`\`

(plus \`"appclips":{"apps":["$team.$clip"]}\` when the App Clip bundle ID is set). Apple's CDN copy:

\`\`\`
curl -sS https://app-site-association.cdn-apple.com/a/v1/$host
\`\`\`

## 3. Build, run, prove

\`\`\`
cp Config/Local.xcconfig.example Config/Local.xcconfig   # put the st_pub_ key in it
scripts/generate.sh && open StraitReference.xcodeproj     # Xcode signs with team $team
scripts/device-proof.sh                                   # XCUITest on the connected iPhone
\`\`\`
MD

# Refresh the values block in README.md.
python3 - "$team" "$app" "$clip" "$group" "$host" <<'PY'
import re, sys
team, app, clip, group, host = sys.argv[1:]
p = 'README.md'
s = open(p).read()
block = (f"<!-- set-team:values -->\n"
         f"Team `{team}` · app `{app}` · App Clip `{clip}` · App Group `{group}` · host `{host}` "
         f"(set with `scripts/set-team.sh`; details in WORKSPACE.md)\n<!-- /set-team:values -->")
s = re.sub(r"<!-- set-team:values -->.*?<!-- /set-team:values -->", block, s, flags=re.S)
open(p, 'w').write(s)
PY

if command -v xcodegen >/dev/null; then scripts/generate.sh; fi
echo "Team $team, app $app, host $host. Next: Dashboard settings in WORKSPACE.md, then scripts/device-proof.sh"
