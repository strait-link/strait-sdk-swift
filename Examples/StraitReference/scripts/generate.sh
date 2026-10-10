#!/usr/bin/env bash
# project.yml -> StraitReference.xcodeproj (xcodegen). STRAIT_APP_CLIP=1 adds the App Clip (beta).
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen" >&2; exit 1; }
spec=project.yml
[[ "${STRAIT_APP_CLIP:-0}" == "1" ]] && spec=project-appclip.yml
xcodegen generate --spec "$spec" --quiet
echo "Generated StraitReference.xcodeproj from $spec"
