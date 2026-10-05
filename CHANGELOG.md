# Changelog

## Unreleased

- Referral codes (preview; shared-spec/proposals/referral-code.md, B21): a matched
  deferred `LinkEvent` (signal match, clipboard claim, `claimHandoff`) carries
  `referralCode` when the engine's reply has a valid one. Legacy `MatchResult` decodes
  `referralCode` too. New public function `replyReferralCode`.

## 0.8.0

- Optional iPhone clipboard boost (shared-spec/SDK-CONTRACT.md B19), **off by default**:
  `StraitLinksConfig(clipboardBoost: true)`. On the first launch only, the SDK asks iOS
  whether a web link is on the clipboard (`UIPasteboard.detectPatterns`, no prompt) and
  only then reads it (iOS shows its paste prompt). A Strait handoff link is claimed via
  `POST /v1/handoff/claim` for an exact match (`route: .clipboard`); anything else falls
  back to signal matching. With the default config the clipboard is never touched.
- `claimHandoff(text:)` / `claimHandoff(itemProviders:)`, `handoffAvailable(completion:)`
  and `StraitPasteButton` (Apple's `UIPasteControl`, iOS 16+, no prompt).
- New core function: `parseHandoffUrl(_:linkHosts:)` (conformance vectors v7); new
  route `clipboard`.
- Privacy manifest comment corrected: the server keeps a keyed hash (HMAC) of the IP
  address and of its IPv6 /64, plus the /24 or /48 network prefix, not "a truncated
  prefix".

## 0.7.2

- Privacy hardening (shared-spec/SDK-CONTRACT.md B18): the URL sent to `/v1/open` and
  `/v1/resolve`, and every report saved in the offline queue (`strait.pendingOpens`),
  is now host + path only; the query string and fragment are dropped, except the first
  `utm_source` pair, which the engine uses for channel attribution. Reports saved by an
  older version are stripped the next time the queue is read. Your app's `LinkEvent`
  (`rawUrl`, `url`, `params`) is unchanged.
- An expired remembered tap id (`strait.lastTap`, older than 7 days or unreadable) is now
  deleted at `start` and on `trackEvent`, instead of only being ignored.
- New core functions: `reportUrl(_:)`, `staleTap(_:now:)` (conformance vectors v6).

## 0.7.1

- Report the portrait screen width so a first launch in landscape still matches the tap
  (shared-spec/SDK-CONTRACT.md B17): `collectDevice()` now sends the shorter side of
  `UIScreen.main.bounds` (it sent the orientation-dependent width).
- New core function: `portraitScreenWidth(_:_:)` (conformance vectors v5).

## 0.7.0

- Every attributed open now supplies the tap id (shared-spec/SDK-CONTRACT.md B16):
  when `/v1/resolve` (Universal Link) or `/v1/match` (fingerprint) returns
  `clickId`, it is remembered as `strait.lastTap` and sent with conversion events.
  A reply without one (older engine) keeps the 0.6.0 behaviour (forget).
- New core function: `replyClickId` (conformance vectors v4).

## 0.6.0

- Conversion events carry the tap id (shared-spec/SDK-CONTRACT.md B15): the tap id
  of the last attributed link open (a browser hand-off `strait_click`) is remembered
  under `strait.lastTap` and sent as `clickId` with `trackEvent` for 7 days. A newer
  short-link or fingerprint open forgets it. `trackEvent(_, clickId:)` overrides it.
- New core API: `eventClickId`, `rememberTap`, `ATTRIBUTION_WINDOW_MS`
  (conformance vectors v3).

## 0.5.0

**Renamed to Strait** (breaking, clean break; no aliases for the old names).

- Package, product, module and targets: `StraitSDK`
  (`import StraitSDK`), test target `StraitSDKTests`. Repo / package identity
  `strait-sdk-swift`.
- Types: `Strait`, `StraitConfig`, `StraitLinks`, `StraitLinksConfig`, `StraitStorage`, `StraitTransport`, `StraitHTTPResponse`, `StraitSubscription`;
  `parseStraitLink` / `parseStraitClick` → `parseStraitLink` / `parseStraitClick`.
- Wire params: `strait_link` and `strait_click` only.
- Storage keys: `strait.deferredChecked`, `strait.pendingOpens` (old values are ignored).
- brand.json is final (Strait, https://usestrait.com, strait.link; the copyright holder is now "The Strait authors").
- Shared vectors (`conformance-vectors.json`) follow the rename.

## 0.4.0

- Every link open is reported exactly once (shared-spec/SDK-CONTRACT.md B14).
  `LinkEvent.id` is now the open id (`newOpenId`, `o_<base36 ms>_<12 chars>`).
  Short links send `openId`, `appState`, `firstLaunch`, `at` with
  `/v1/resolve` (and fall back to `/v1/open` when the engine didn't record
  it); custom-scheme hand-offs and own https links are reported via
  `POST /v1/open` without delaying the event.
- Reports that get no answer, 429 or 5xx are saved in `StraitStorage` under
  `strait.pendingOpens` and retried on start, when the app becomes active and
  after any successful report (pruned to 7 days / 100). New
  `pendingOpenReports(completion:)` and `flushOpenReports(completion:)`.
- B4: a `strait_click` tap id is removed from the destination;
  `ClassifiedUrl.destination` gains `clickId` (source-breaking for code that
  pattern-matches it).
- B6/B8: the deferred `/v1/match` sends `openId` + `at`; the check is marked
  done only once the engine answered (no answer / 429 / 5xx → `network`,
  retried next launch). `checkDeferred()` sends no `openId`.
- New pure helpers checked against `conformance-vectors.json` v2:
  `parseStraitClick`, `takeClickId`, `pruneOpenQueue`, `shouldRetryReport`,
  `newOpenId`, `OPEN_QUEUE_MAX`, `OPEN_QUEUE_MAX_AGE_MS`.
- `at` is sent as whole milliseconds on `/v1/resolve`, `/v1/match` and `/v1/open`.
- `StraitStorage.getItem` can't fail (it returns `String?`), so the RN rule
  "unreadable storage = deferred already checked" has no Swift equivalent.

### Packaging

- Ready for Swift Package Manager: a version tag `vX.Y.Z` is the release
  (SwiftPM reads tags straight from the repo; no registry account). The release
  workflow builds and tests the tag on macOS and checks this changelog names it.
- The repo URL and copyright holder come from `brand.json` (README install block
  + LICENSE applied by `scripts/brand.mjs`). MIT `LICENSE` added.

## 0.3.0

- `StraitLinks` client at parity with the React Native SDK
  (shared-spec/SDK-CONTRACT.md B1–B6, B8–B13): Universal Links / custom scheme
  via `handle(url:)` / `handle(userActivity:)`, short-link resolve, app-state
  labels from UIApplication notifications, deferred check once per install,
  `onLink` with replay, `onLinkStart`, `checkDeferred`, `trackEvent`,
  `reportFingerprint`, `compareFingerprint`.
- Pure helpers ported 1:1 and checked against `conformance-vectors.json`:
  `browserScreenWidth`, `splitUrl`, `normalizeLinkHosts`, `parseStraitLink`,
  `classifyUrl`, `AppStateTracker`.
- `collectDevice().screenWidth` now uses `browserScreenWidth` (ceil), matching
  what Safari reports. `DeviceFields` and `collectDevice()` are public.
- `Strait.resolveDeferredLink` unchanged.

## 0.1.0

- Deferred match (`Strait.resolveDeferredLink`) with golden-vector signature parity.
