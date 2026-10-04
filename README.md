# StraitSDK (iOS / Swift)

Deferred deep linking for native iOS — the user taps your link, installs, and
lands on the right screen. Signal matching works with no clipboard and no prompt;
an optional clipboard boost (off by default) gives an exact match for apps that
opt in. How it works and what it uses: [How iPhone install matching works](https://straitlink.in/docs/iphone-install-matching/).

Part of [Strait](https://straitlink.in). The match signature is a Swift port kept in lockstep with
the server and every other SDK via shared golden vectors
(run by `swift test` in CI). 32-bit hash overflow is matched with `Int32` + `&*`.

> ⚠️ Verified by CI (`swift test` on macOS) against the golden vectors. Wire-up
> into a real app + on-device deferred-install verification still needs Xcode.

## Install (Swift Package Manager)

<!-- brand:install -->
Xcode: **File → Add Package Dependencies…** and paste the repo URL, or in `Package.swift`:

```swift
.package(url: "https://github.com/bazingga08/strait-sdk-swift", from: "0.8.0")
// target dependency: .product(name: "StraitSDK", package: "strait-sdk-swift")
```
<!-- /brand:install -->

## Use — `StraitLinks` (direct + deferred links, analytics)

Create one client at launch and keep it for the app's lifetime.

```swift
import StraitSDK

let strait = StraitLinks(StraitLinksConfig(
    publishableKey: "st_pub_live_…",
    endpoint: "https://<your-handle>.strait.link",
    linkHosts: ["links.yourbrand.com"]   // extra short-link domains: URLs or bare hosts
))

strait.onLinkStart { start in showOpeningLink(start.id) }   // loading state
strait.onLink { event in                                    // replays past events
    guard event.matched, let path = event.path else { return }
    router.open(path, params: event.params ?? [:])
}
```

### UIKit with scenes (SceneDelegate)

```swift
func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
    // The link that launched the app from closed (Universal Link or custom scheme).
    let launchURL = options.userActivities.first(where: { $0.activityType == NSUserActivityTypeBrowsingWeb })?.webpageURL
        ?? options.urlContexts.first?.url
    strait.start(initialURL: launchURL)       // also runs the deferred check, once per install
}

func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    strait.handle(userActivity: userActivity)  // Universal Link while running
}

func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    URLContexts.forEach { strait.handle(url: $0.url) }   // yourapp://… browser hand-off
}
```

Without scenes, do the same from `application(_:didFinishLaunchingWithOptions:)`
(`launchOptions?[.url]`), `application(_:continue:restorationHandler:)` and
`application(_:open:options:)`.

### SwiftUI

```swift
@main struct ShopApp: App {
    init() { strait.start() }
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { strait.handle(url: $0) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { strait.handle(userActivity: $0) }
        }
    }
}
```

SwiftUI delivers the cold-launch URL through `onOpenURL` too, so it is labelled
by app state rather than `closed`; if you need `closed` (and the first-launch
deferred skip), adopt a `UIApplicationDelegateAdaptor`/scene delegate and pass
the launch URL to `start(initialURL:)`.

### What Strait records automatically (no extra code)

Every time a link opens the app, the SDK reports it once (contract B14):

| How the app opened | Reported via | Joined to |
|---|---|---|
| Universal Link tapped in WhatsApp, Gmail, Messages… | `/v1/resolve` (the lookup is the report) | the link; also counted as a tap |
| Browser handed off to the app (`yourapp://…`) | `/v1/open` | the exact tap (`strait_click`, removed before your app sees the URL) |
| First open after an App Store install | `/v1/match` | the matched tap |
| Your own https links | `/v1/open` | the URL's host + path (plus `utm_source`, for the channel); query and fragment never leave the device (B18) |

Reports that can't be sent (offline, server busy) are saved in `storage`
(`strait.pendingOpens`) and retried on the next `start`, whenever the app
becomes active, and after any report that gets through, for up to 7 days
(max 100). The engine de-duplicates by open id (`LinkEvent.id`), so nothing is
counted twice. Navigation never waits for a report. The first launch of an
install is marked as such, so dashboards can tell **new users** (installed and
opened) from **existing users** (already had the app). The deferred check is
only marked done once the server answered, so an offline first launch is
retried on the next launch.

```swift
strait.pendingOpenReports { count in }   // saved reports waiting to be sent (debugging)
strait.flushOpenReports { }              // send them now
```

### Lifecycle and storage

- `start` observes `UIApplication` didBecomeActive / willResignActive /
  didEnterBackground to label links `background` vs `foreground`. Set
  `observeLifecycle: false` and call `strait.onAppState(.active | .inactive | .background)`
  to feed it yourself. `stop()` removes the observers.
- The once-per-install flag `strait.deferredChecked` and the pending open
  reports `strait.pendingOpens` live in `UserDefaults.standard` by default;
  pass any `StraitStorage` to change that.
- `transport:` (a `StraitTransport`, default `URLSession.shared`), `now:` and
  `device:` are injectable for tests. Callbacks run on the main queue
  (`callbackQueue: nil` runs them on whatever thread finished the work).

### Analytics + fingerprint check

```swift
strait.trackEvent("purchase", value: 49.99, currency: "USD", linkId: event.linkId) { ok in }
// The event carries the tap id of the last attributed link open for 7 days, so
// revenue lands on that tap's channel / A/B variant (contracts B15/B16): a
// browser hand-off, or the engine's reply to a Universal Link or a deferred
// match. A newer open replaces the older tap. Pass `clickId:` to set it yourself.
strait.reportFingerprint { json in }   // POST /v1/debug/fingerprint, origin "app"
strait.compareFingerprint { json in }  // engine's app-vs-browser comparison
strait.checkDeferred { event in }      // re-run the deferred check (debugging)
```

### Clipboard boost (optional, iOS, contract B19)

By default the SDK finds the tap on first launch by **signal matching**: the
server compares the tap with the first launch using the IP address (stored only
as a keyed hash), screen size, language, time zone and iOS version, kept for one
hour and used only to open the right screen in your app. It never touches the
clipboard.

For an **exact** match you can opt in to the clipboard boost:

1. Dashboard → Settings → turn on **Clipboard boost**. The "Get the app" button
   on your iPhone link page then also copies a one-time Strait link
   (`https://<your-handle>.strait.link/h/<token>`, single use, 24 hours).
2. In the app:

```swift
let strait = StraitLinks(StraitLinksConfig(
    publishableKey: "st_pub_live_…",
    endpoint: "https://<your-handle>.strait.link",
    clipboardBoost: true
))
```

On the first launch only, the SDK asks iOS whether the clipboard probably holds
a web link (`UIPasteboard.detectPatterns`, **no prompt**). Only if it does, it
reads the clipboard, and **iOS shows its "Allow Paste" prompt** at that moment.
If the person allows it and the text is a Strait handoff link for your link
hosts, the SDK claims it (`POST /v1/handoff/claim`) and you get the exact
destination (`route: .clipboard`). Anything else (no link, another site's link,
a used or expired token, "Don't Allow") falls back to signal matching. Only the
token is ever sent, never other clipboard text.

**No prompt at all:** show Apple's Paste button instead. iOS shows no prompt
because the person's tap is the consent (iOS 16+):

```swift
// UIKit
if #available(iOS 16.0, *) {
    let button = StraitPasteButton(straitLinks: strait)
    button.onResult = { event in /* event.matched, event.url */ }
    view.addSubview(button)
}

// SwiftUI
PasteButton(payloadType: URL.self) { urls in
    strait.claimHandoff(text: urls.first?.absoluteString)
}
```

`strait.handoffAvailable { likely in }` tells you (no prompt) whether a web link
is on the clipboard, so you can decide whether to show the button.

**Turning matching off:** Dashboard → Settings → **iPhone install matching**.
When it is off, Strait stores no device signals at the tap and iPhone installs
are only matched through the clipboard boost (if on). Android installs keep
using the Play Install Referrer.

### `LinkEvent`

`id` · `kind` (`direct` / `deferred`) · `route` (`app_link`, `custom_scheme`,
`fingerprint`, `clipboard`) · `appState` (`closed`, `background`, `foreground`) · `matched` ·
`reason` (`not_found`, `expired`, `password_protected`, `no_match`, `network`,
`invalid_url`, `not_handoff`, `handoff_unknown`, `handoff_used`, `handoff_expired`) · `rawUrl` · `url` · `path` · `params` · `linkId` · `ms` · `at`.
`id` is the open id Strait records the open under (`o_<base36 ms>_<12 chars>`).
A `LinkStart` with the same `id` fires first, before any network call.

## Behaviours (shared-spec/SDK-CONTRACT.md)

| # | Status |
|---|---|
| B1 publishableKey in every body | ✓ (`/v1/match`, `/v1/resolve`, `/v1/open`, `/v1/event`, `/v1/debug/fingerprint`; GET compare sends it as a query param) |
| B2 `screenWidth = browserScreenWidth(UIScreen.main.bounds.width)` | ✓ |
| B3 short links on link hosts → `POST /v1/resolve {publishableKey,url,platform:'ios'}` | ✓ (hosts via `normalizeLinkHosts`) |
| B4 custom scheme / https classification (`classifyUrl`), `strait_click` removed (`takeClickId`) | ✓ |
| B5 app-state labels (`AppStateTracker`, 2000/1000 ms) | ✓ |
| B6 deferred once per install, skipped-but-marked when launched by a link; marked only once the engine answered | ✓ |
| B7 Android Play Install Referrer | n/a on iOS (`parseStraitLink` / `parseStraitClick` are ported for parity) |
| B8 iOS deferred `POST /v1/match` with device fields + `openId`, `at` | ✓ |
| B9 one event type, replay, start signal | ✓ |
| B10 never throws; network → `matched:false, reason:'network'` | ✓ |
| B11 JSON via `JSONSerialization` | ✓ |
| B12 `splitUrl` without `URLComponents` | ✓ |
| B13 `trackEvent`, `reportFingerprint`, `compareFingerprint` | ✓ |
| B14 every open reported once; offline reports queued and retried | ✓ (`pendingOpenReports`, `flushOpenReports`) |
| B15 conversion events carry the tap id of the last attributed open (7 days; `clickId:` overrides) | ✓ (`strait.lastTap`) |
| B16 every attributed open supplies the tap id (`/v1/resolve` and `/v1/match` reply `clickId`, `replyClickId`) | ✓ |
| B17 `screenWidth` is the portrait width: `portraitScreenWidth(bounds.width, bounds.height)` in any orientation | ✓ |
| B18 reported/queued URLs stripped to host + path (+ `utm_source`) via `reportUrl`; expired remembered taps deleted (`staleTap`) | ✓ |
| B19 clipboard boost: opt-in `clipboardBoost` (default off), `detectPatterns` first (no prompt), read only when a URL is likely, `parseHandoffUrl`, `POST /v1/handoff/claim`, fallback to `/v1/match`; `claimHandoff(text:)` + `StraitPasteButton` | ✓ (B1–B6, B8–B19) |

Both `test-vectors.json` (signature) and `conformance-vectors.json` (pure
helpers) run under `swift test` in CI.

## Deferred match only (legacy, still supported)

```swift
let result = await Strait.resolveDeferredLink(
    StraitConfig(publishableKey: "st_pub_live_…", endpoint: "https://<your-handle>.strait.link")
)
if result.matched, let url = result.longUrl {
    // route to url
}
```

**Publishable key:** Dashboard → Get started → Publishable key (`st_pub_live_…`).
It's safe to include in your app. Never put your secret key (`st_live_…`) in an app.

Collects only coarse device fields (screen width, scale, language, timezone);
the **server** adds the observed IP and computes the match signature.
