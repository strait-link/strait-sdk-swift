#!/usr/bin/env bash
# The real-iPhone proof, scripted: xcodebuild test on the connected iPhone.
#
#   scripts/device-proof.sh              # Universal Links, AASA, store sheet, scheme, then the 4 combinations
#   scripts/device-proof.sh --no-combos  # skip the interactive dashboard-combination runs
#   scripts/device-proof.sh --only test04_UniversalLinkCold
#
# Needs: scripts/set-team.sh done (DEVELOPMENT_TEAM set), Xcode signed in to that
# team, an iPhone connected (USB or same Wi-Fi) with Developer Mode on, and the
# publishable key in STRAIT_PK or Config/Local.xcconfig. Optional:
#   STRAIT_LINK       a short link on the host (default https://<host>/bl-product, strait-dev's
#                     test link to https://example.com/p/42?color=red)
#   STRAIT_LINK_PATH  the path that destination opens (default /p/42)
#   DEVICE_ID         the iPhone's UDID (default: the first connected iPhone)
# Output: proof/<time>/ with each .xcresult, exported screenshots and SUMMARY.txt.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

combos=1; only=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-combos) combos=0 ;;
    --only) only="$2"; shift ;;
    *) echo "unknown option $1" >&2; exit 64 ;;
  esac
  shift
done

team="$(sed -n 's/^DEVELOPMENT_TEAM = //p' Config/Team.xcconfig)"
host="$(sed -n 's/^STRAIT_LINK_HOST = //p' Config/Team.xcconfig)"
[[ -n "$team" ]] || { echo "No team yet: run scripts/set-team.sh <TEAM_ID> <BUNDLE_PREFIX> first." >&2; exit 2; }
pk="${STRAIT_PK:-}"
if [[ -z "$pk" && -f Config/Local.xcconfig ]]; then pk="$(sed -n 's/^STRAIT_PUBLISHABLE_KEY *= *//p' Config/Local.xcconfig)"; fi
[[ "$pk" == st_pub_* ]] || { echo "Set STRAIT_PK (st_pub_…) or Config/Local.xcconfig." >&2; exit 2; }
link="${STRAIT_LINK:-https://$host/bl-product}"
link_path="${STRAIT_LINK_PATH:-/p/42}"

udid="${DEVICE_ID:-}"
if [[ -z "$udid" ]]; then
  tmp="$(mktemp)"
  xcrun devicectl list devices --json-output "$tmp" >/dev/null 2>&1 || true
  udid="$(python3 - "$tmp" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
for d in devices:
    hw = d.get("hardwareProperties", {}); conn = d.get("connectionProperties", {})
    if hw.get("platform") == "iOS" and hw.get("reality") == "physical" and conn.get("tunnelState") != "unavailable":
        print(hw.get("udid", "")); break
PY
)"
  rm -f "$tmp"
fi
[[ -n "$udid" ]] || { echo "No iPhone found. Connect it, unlock it, trust this Mac, turn on Developer Mode (Settings > Privacy & Security)." >&2; exit 3; }

out="proof/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$out"
scripts/generate.sh
echo "Device $udid · team $team · host $host · link $link · output $out"

run() { # name, extra env..., -- only-testing args...
  local name="$1"; shift
  local envs=() tests=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift
  for t in "$@"; do tests+=("-only-testing:StraitReferenceUITests/DeviceProofUITests/$t"); done
  local status=0
  # TEST_RUNNER_* must be ENVIRONMENT variables (xcodebuild hands them to the
  # test runner without the prefix), not build-setting arguments.
  env TEST_RUNNER_STRAIT_ENDPOINT="https://$host" TEST_RUNNER_STRAIT_PK="$pk" TEST_RUNNER_STRAIT_LINK="$link" TEST_RUNNER_STRAIT_LINK_PATH="$link_path" \
    ${envs[@]+"${envs[@]}"} xcodebuild test -project StraitReference.xcodeproj -scheme StraitReference \
    -destination "id=$udid" -allowProvisioningUpdates -resultBundlePath "$out/$name.xcresult" \
    ${tests[@]+"${tests[@]}"} 2>&1 | tee "$out/$name.log" | grep -E "Test Case .*(passed|failed|skipped)|error:" || status=$?
  xcrun xcresulttool export attachments --path "$out/$name.xcresult" --output-path "$out/$name-shots" >/dev/null 2>&1 || true
  # Give the exported screenshots and notes their test names (01-runtime-choice.png ...).
  python3 scripts/name-shots.py "$out/$name-shots" || true
  {
    echo "== $name"
    grep -E "Test Case .*(passed|failed|skipped)" "$out/$name.log" | sed -E 's/^.*Test Case .-\[[^ ]+ ([^]]+)\]. /  \1 /' || true
  } >> "$out/SUMMARY.txt"
}

if [[ -n "$only" ]]; then
  run "only-$only" -- "$only"
else
  run core -- test01_RuntimeChoiceIsLive test02_AASAListsThisApp test03_UniversalLinkWarm \
    test04_UniversalLinkCold test07_StoreSheet test08_CustomSchemeFallback
  if [[ "$combos" == 1 ]]; then
    for c in "1 0" "0 1" "1 1" "0 0"; do
      set -- $c; d="$1"; p="$2"
      words="Device matching=$([[ $d == 1 ]] && echo ON || echo OFF), Paste handoff=$([[ $p == 1 ]] && echo ON || echo OFF)"
      read -r -p "Dashboard -> Settings -> iPhone installs: set $words. Enter = run, s = skip: " ans || ans=s
      [[ "$ans" == "s" ]] && { echo "== combo d$d-p$p skipped" >> "$out/SUMMARY.txt"; continue; }
      tests=(test01_RuntimeChoiceIsLive test05_DeferredForThisCombination)
      [[ "$p" == 1 ]] && tests+=(test06_PasteButtonClaimsHandoff)
      run "combo-d$d-p$p" TEST_RUNNER_STRAIT_EXPECT_DEVICE="$d" TEST_RUNNER_STRAIT_EXPECT_PASTE="$p" -- "${tests[@]}"
    done
  fi
fi
echo; cat "$out/SUMMARY.txt"; echo; echo "Screenshots: $out/*-shots/"
