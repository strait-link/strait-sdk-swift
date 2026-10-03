# Changelog

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
