# Changelog

## 0.9.5

- Faster start-up: `StraitLinks(config)` no longer compiles a regular expression. The first
  `NSRegularExpression` in a process loads ICU, which made `StraitLinks(config)` take 0.80 ms on the
  main thread; it now takes 0.02 ms (link-host checks are plain ASCII scans with the same rules,
  tested against the old regex code). One edge case now matches the other SDKs: a port written in
  non-ASCII digits (`a.com:١٢`) is no longer accepted as a link host. No API change.
- README: a "Size and speed" table (binary size in an app, start-up time, how each was measured).

## 0.9.4

- New `StraitLinks.doctor(bundleId:completion:)`: a setup check for debug builds (contract B23,
  shared-spec ADR 0002). One GET of `{endpoint}/.well-known/apple-app-site-association`, then the
  pure `doctorFindings(publishableKey:endpoint:platform:appId:file:)` over the key (publishable,
  secret or neither), the endpoint, the file and the bundle ID (`app.listed` when an appID ends
  with `.{bundleId}`; the title shows the full appID). Never throws, prints each finding, completes
  on `callbackQueue` with `DoctorReport { ok, findings }`. Same ids and wording in every SDK. No new
  dependency, no engine change.

## 0.9.3

- `/v1/resolve` and `/v1/open` reports (queued retries too) and the store sheet now send `deviceClass`
  (`"tablet"` on an iPad, `"phone"` on an iPhone; contract B14, engine ADR 0039). iPadOS Safari sends a
  Mac user agent, so only the app can tell Strait a tap came from an iPad. New
  `StraitLinksConfig.deviceClass` (defaults to the current device, `nil` sends nothing); older engines
  ignore the field. Conformance vectors v9 (the `deviceClass` size rule is exempt: iOS reads the model).
- Docs: iPhone links are live (tested on a real iPhone 16 Pro, iOS 26, 21 Oct 2026), iPhone install
  matching is opt-in (off until you choose it), the store sheet is new and the App Clip handoff is
  optional and not yet tried on a device, in the README, the reference app and the doc comments. No
  behaviour change.
- Reference app UI tests run on iPhone and iPad simulators (`SafariHomepageUITests` added).

## 0.9.2

- Fix: a link that opens the app while the first-launch deferred check is still running is no
  longer followed by that check's *match* either (0.9.1 held back only its "no link" event). The
  app stays on the screen the person just tapped instead of jumping to a stale pre-install
  destination. The engine still counts the install and records and attributes the match as before,
  the check is still marked done, and the match is not replayed to late `onLink` subscribers.
  `checkDeferred()` still completes with (and delivers) its answer (contract B6).
- Paste handoff: once a link has opened the app in this launch, the first-launch check no longer
  reads `UIPasteboard`, so iOS shows no "Allow Paste" prompt for an answer that won't be
  delivered. Checked again right after the prompt-free `detectPatterns`; a clipboard already read
  is claimed as before (contract B6/B19).
- Known gap (no API change): if the check had already sent its `onLinkStart` when the link arrived,
  no `onLink` event with that start's `id` follows. The documented pattern (loading on at any
  `onLinkStart`, off at any `onLink`) stays correct because the link's own start and event come
  after it; an app that tracks loading per `id` should also clear pending deferred ids when a
  `.direct` event arrives.

## 0.9.1

- Fix: a link that opens the app while the first-launch deferred check is still running is no
  longer followed by that check's "no link" event (`matched: false`, `no_match` or `network`).
  The documented SwiftUI setup (`start()` in `init`, links from `onOpenURL`) hit this on every
  first launch from a link: the link was delivered, then the check's `false`, so an app that
  routes home on `!matched` left the right screen (found with the React Native SDK on an Android
  emulator, 13 Oct). The check still runs and counts the install, and is marked done (or retried
  next launch) as before; only its no-link event is not delivered, and it sends no
  `onLinkStart` once a link is here (a loading state would never end). A deferred match is still
  delivered; `checkDeferred()` is unchanged (contract B6).

## 0.9.0

- Smaller public API (SDK-23, decision record: shared-spec `docs/adr/0001-sdk-public-api-surface.md`).
- The design tokens are internal: `StraitTokens`, `StraitColor`, `StraitColors` and the rest of
  `StraitTokens.swift` (about 230 symbols), plus `StraitTokens.dynamic(_:)` and `StraitColor.uiColor`.
  The SDK's own UI (`StraitPasteButton`) still uses them. A deep-link SDK shouldn't make its colour
  palette a versioned promise. The README's "Design tokens" section is gone. The reference app
  compiles its own copy of the two files.
- The contract helpers in `Core.swift` are internal: `classifyUrl`, `splitUrl`, `SplitUrl`,
  `normalizeLinkHosts`, `parseStraitLink`, `parseStraitClick`, `takeClickId`, `ClickIdSplit`,
  `ClassifiedUrl`, `pageLinkLongLink`, `pruneOpenQueue`, `rememberTap`, `eventClickId`, `staleTap`,
  `reportUrl`, `replyClickId`, `replyReferralCode`, `shouldRetryReport`, `newOpenId`,
  `replyPasteHandoff`, `replyInstallSettings`, `parseHandoffUrl`, `browserScreenWidth`,
  `AppStateTracker` and the queue and window constants; also `numStr` and `regionFromTimezone`. None
  were in the docs. Still public: `StraitLinks` and its types, `Strait.resolveDeferredLink`,
  `MatchResult`, `DeviceFields`, `InstallSettings`, `portraitScreenWidth`, `LinkRoute`,
  `AppStateAtLink`, `AppLifecycleState`, `computeSignature`, `h32`, the store sheet, the Paste button
  and the App Clip helpers.

## 0.8.2

- `checkDeferred()` (the debug / settings re-check) now sends `"record": false` on `/v1/match`, so the
  engine answers the match without adding an install, an open or an `install.matched` webhook
  (contract B6: it never adds an install). The once-per-install check is unchanged. Takes effect
  once the engine with `record` support is live; an older engine ignores the field.

## 0.8.1

- Real-device readiness (beta): `Examples/StraitReference`, a signable reference app
  (xcodegen) with Universal Links (`applinks:<host>`, UIKit scenes so a cold start is
  `closed`), the `straitref://` fallback, store sheet, Paste button, a Settings screen with
  the live runtime choice and an AASA check, an optional App Clip (`STRAIT_APP_CLIP=1`),
  `scripts/set-team.sh`, `build-device.sh`, `device-proof.sh` (XCUITest on a connected
  iPhone) and `testflight.sh` (archive + `-exportArchive` upload). Test plan in
  `Examples/StraitReference/TEST-PLAN.md`.
- `StraitLinks.lastInstallSettings` / `InstallSettings` / `replyInstallSettings(_:at:)`:
  the workspace's iPhone choice from the latest `/v1/match` reply, for settings and debug
  screens (never stored; nil before an answer or with an older engine).
- `StraitAppClip` (beta): App Clip -> full app handoff through a shared App Group
  (`saveInvocation` in the App Clip, `takeInvocation` once in the full app, 7-day window,
  https only), passed to `start(initialURL:)` for an exact deferred link.
- Design system v5: `StraitPasteButton` now defaults to the Strait look
  (`StraitPasteButton.straitConfiguration()`): the orange fill `#FF6A13` with ink text
  `#0F0D0A` (6.8:1) in light and dark, 8 pt corners, icon and label, at least 44 pt tall.
  Pass a `UIPasteControl.Configuration` to keep your own colours. New `StraitTokens`
  (generated from brand v5: colours light / dark, spacing, radii, type, durations) and
  `StraitTokens.dynamic(_:)` / `StraitColor.uiColor` for UIKit. Tests check the brand colour,
  AA contrast and that no blue or cool grey is in the palette.
- README: the common Strait SDK header (logo, promise, badges, links), a platform features
  table with the iPhone beta truth, Paste button screenshots, and "Docs and support".
- iPhone deferred-link method chosen by the customer at runtime (founder decision 10 Oct 2026):
  the once-per-install check reads the workspace's choice from the `/v1/match` reply
  (`ios.pasteHandoff`, Dashboard → Settings → iPhone installs) and reads the clipboard only
  when it is on and device matching found nothing (or is off). Nothing is baked into the app
  build and the choice is never stored, so changing it needs no app release. A reply without
  the field (older engine) means off. When `/v1/match` gets no answer, 429 or 5xx, the
  clipboard is left alone and the check runs again next launch. `StraitLinksConfig.clipboardBoost`
  is deprecated and ignored. New public function `replyPasteHandoff(_:)`.
- Clipboard boost order (B19): the first-launch deferred check now runs device matching
  (`/v1/match`) first; the clipboard is read and the handoff claimed only when that returns
  no match or fails. A device match no longer shows iOS's "Allow Paste" prompt. Both attempts
  share one `openId` and only the final `LinkEvent` is emitted. `StraitPasteButton` is unchanged.
- Store sheet (beta): `StraitLinks.openStoreSheet(url:options:presenter:completion:)` (also
  `Strait.openStoreSheet(_:…)`) shows `SKStoreProductViewController` or `SKOverlay` inside your
  app after `POST /v1/store-sheet`, saves the device match for that tap (`/v1/match-save`) and,
  opt-in, copies the clipboard-boost handoff link. New `StoreSheet`, `StoreProduct`,
  `StoreSheetOptions`, `StoreSheetResult`, `StoreSheetPresenting`, `SystemStoreSheetPresenter`
  (iOS), `StraitPasteboardWriting` (`SystemPasteboard` conforms).
- Old Firebase Dynamic Links (shared-spec/SDK-CONTRACT.md B22, conformance vectors v8). Add your
  `<x>.page.link` host to `linkHosts` (and keep `applinks:<x>.page.link` in your app build): a page.link
  **short** link is looked up through `/v1/resolve` like any short link (the engine matches the old host +
  code of links you imported), and a page.link **long** link (`https://<x>.page.link/?link=<url>&…`) opens
  its `link=` destination straight away, on the device, with no lookup. Only `*.page.link` hosts at the root
  path, only an http(s) `link`. New public function `pageLinkLongLink`. Not yet tested on a real iPhone.

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

- Package, product, module and targets: `BridgeSDK` → `StraitSDK`
  (`import StraitSDK`), test target `StraitSDKTests`. Repo / package identity
  `strait-sdk-swift`.
- Types: `Bridge` → `Strait`, `BridgeConfig` → `StraitConfig`, `BridgeLinks` →
  `StraitLinks`, `BridgeLinksConfig` → `StraitLinksConfig`, `BridgeStorage` →
  `StraitStorage`, `BridgeTransport` → `StraitTransport`, `BridgeHTTPResponse` →
  `StraitHTTPResponse`, `BridgeSubscription` → `StraitSubscription`;
  `parseBridgeLink` / `parseBridgeClick` → `parseStraitLink` / `parseStraitClick`.
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
- Reports that get no answer, 429 or 5xx are saved in `BridgeStorage` under
  `bridge.pendingOpens` and retried on start, when the app becomes active and
  after any successful report (pruned to 7 days / 100). New
  `pendingOpenReports(completion:)` and `flushOpenReports(completion:)`.
- B4: a `bridge_click` tap id is removed from the destination;
  `ClassifiedUrl.destination` gains `clickId` (source-breaking for code that
  pattern-matches it).
- B6/B8: the deferred `/v1/match` sends `openId` + `at`; the check is marked
  done only once the engine answered (no answer / 429 / 5xx → `network`,
  retried next launch). `checkDeferred()` sends no `openId`.
- New pure helpers checked against `conformance-vectors.json` v2:
  `parseBridgeClick`, `takeClickId`, `pruneOpenQueue`, `shouldRetryReport`,
  `newOpenId`, `OPEN_QUEUE_MAX`, `OPEN_QUEUE_MAX_AGE_MS`.
- `at` is sent as whole milliseconds on `/v1/resolve`, `/v1/match` and `/v1/open`.
- `BridgeStorage.getItem` can't fail (it returns `String?`), so the RN rule
  "unreadable storage = deferred already checked" has no Swift equivalent.

### Packaging

- Ready for Swift Package Manager: a version tag `vX.Y.Z` is the release
  (SwiftPM reads tags straight from the repo; no registry account). The release
  workflow builds and tests the tag on macOS and checks this changelog names it.
- The repo URL and copyright holder come from `brand.json` (README install block
  + LICENSE applied by `scripts/brand.mjs`). MIT `LICENSE` added.

## 0.3.0

- `BridgeLinks` client at parity with the React Native SDK
  (shared-spec/SDK-CONTRACT.md B1–B6, B8–B13): Universal Links / custom scheme
  via `handle(url:)` / `handle(userActivity:)`, short-link resolve, app-state
  labels from UIApplication notifications, deferred check once per install,
  `onLink` with replay, `onLinkStart`, `checkDeferred`, `trackEvent`,
  `reportFingerprint`, `compareFingerprint`.
- Pure helpers ported 1:1 and checked against `conformance-vectors.json`:
  `browserScreenWidth`, `splitUrl`, `normalizeLinkHosts`, `parseBridgeLink`,
  `classifyUrl`, `AppStateTracker`.
- `collectDevice().screenWidth` now uses `browserScreenWidth` (ceil), matching
  what Safari reports. `DeviceFields` and `collectDevice()` are public.
- `Bridge.resolveDeferredLink` unchanged.

## 0.1.0

- Deferred match (`Bridge.resolveDeferredLink`) with golden-vector signature parity.
