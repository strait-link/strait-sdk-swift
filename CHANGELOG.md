# Changelog

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
