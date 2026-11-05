# ADR 0002: send `appVersion` + `sdkVersion` with recorded opens and installs

Date: 5 Nov 2026 · Status: accepted · Backlog: td2-23 · Same wire contract in every Strait SDK and the engine

## Problem
When a customer says "links stopped working", support's first question is "which app version?". Today the
engine can't answer it: no recorded open or install says which app build (or which SDK) sent it.

## Who it serves
Support and the app team debugging a broken release; the founder triaging an SDK regression by version.

## Options
1. **Do nothing**: ask the customer, who often doesn't know. Slow, and wrong for old phones that never updated.
2. **A header (`User-Agent` / `X-Strait-SDK`)**: the engine would have to read headers on some routes and
   bodies on others; the existing fields (openId, appState, firstLaunch) are all body fields.
3. **Two optional body fields, `appVersion` and `sdkVersion`, on the requests that record.** **Chosen.**

## Design
- `appVersion` = `CFBundleShortVersionString` from `Bundle.main.infoDictionary` (no build number), via
  `StraitLinksConfig.appVersion` (default `currentAppVersion()`, injectable like `deviceClass`).
- `sdkVersion` = `StraitLinks.sdkVersion`, pinned by a test to the newest `## X.Y.Z` in CHANGELOG.md (the
  release workflow checks tags against the changelog, so a forgotten bump fails the release's tests).
- Sent on `/v1/open` (added at send time, so saved reports retried later carry them), `/v1/resolve`,
  `/v1/match` (the once-per-install check and the legacy `Strait.resolveDeferredLink`) and
  `/v1/handoff/claim`. Not on `/v1/lookup` (opt-out path), `/v1/event`, the debug re-check (`record:false`)
  or the store sheet. Nothing while switched off (the one HTTP helper refuses every call).
- Engine rule: 1-64 printable ASCII, anything else silently dropped. The SDK trims, caps at 64 and leaves the
  field out when empty or not printable ASCII.

## Security / privacy
- Not personal data and not a fingerprint signal: every install of the same build sends the same value.
- Spoofing: a modified app can send any version; it is a support hint, never used for matching or billing.
- Abuse / DoS: bounded to 64 ASCII characters on both sides.
- Privacy manifest: no key change. Reading the app's own Info.plist is not a required-reason API; the
  manifest comment now says the open reports carry the app and SDK versions.

## Cost
Two short strings per recorded open. No new storage on the device.
