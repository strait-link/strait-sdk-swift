# Strait SDK for iOS (Swift)

`StraitSDK` (iOS / Swift)

> **Availability:** iPhone install matching: **Beta** (not yet proven on a real iPhone) · SDK: Beta (installed from GitHub).
> [Platform status](https://straitlink.in/platform-status/) · [Docs](https://straitlink.in/docs/)

Deferred deep linking for native iOS: the user taps your link, installs, and
lands on the right screen. On iPhone, **device matching** is the primary method
(on by default, no clipboard, no prompt) and **paste handoff** (the clipboard
boost, off by default) is the secondary method for apps that opt in. Each is a
workspace switch in Dashboard → Settings → iPhone installs. Navigating, not
tracking: the signals route one tap and are never used to build profiles. How it works and what it uses: [How iPhone install matching works](https://straitlink.in/docs/iphone-install-matching/).

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

### Device matching (primary) and paste handoff (secondary), iOS

By default the SDK finds the tap on first launch by **device matching**: the
server compares the tap with the first launch using the IP address (stored only
as a keyed hash), its network block and provider, screen size, language, time
zone and iOS version. It is navigating, not tracking: the signals are used only
to open the right screen in your app, one tap gives at most one match, and
nothing is used for profiles or advertising. A tap can be matched for **1 hour**;
the server's nightly cleanup erases its signals once that hour is a day old, so
they are gone **within about 2 days of the tap** (at most 49 hours). Device
matching never touches the clipboard.

Apple's rules say apps may not fingerprint devices, even with permission.
Device matching sits close to that line, so if you'd rather not take the App
Review risk, use **Switch to paste only** in Dashboard → Settings → iPhone
installs (device matching off, paste handoff on).

### Paste handoff (clipboard boost, optional, contract B19)

For an **exact** match you can opt in to paste handoff:

1. Dashboard → Settings → turn on **Paste handoff (fallback)**. The "Get the app" button
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

On the first launch only, the SDK runs device matching first (`POST /v1/match`).
If that finds the install, the clipboard is never touched and no prompt shows.
Only if it finds no match (or the request fails), the SDK asks iOS whether the
clipboard probably holds a web link (`UIPasteboard.detectPatterns`, **no
prompt**). Only if it does, it reads the clipboard, and **iOS shows its "Allow
Paste" prompt** at that moment. If the person allows it and the text is a Strait
handoff link for your link hosts, the SDK claims it (`POST /v1/handoff/claim`)
and you get the exact destination (`route: .clipboard`). Anything else (no link,
another site's link, a used or expired token, "Don't Allow") keeps the device
match result. Both attempts share one `openId`, so one install is one event. Only the
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

When `clipboardBoost` is on, the SDK still tries device matching first on the
first launch and reads the clipboard only when that finds nothing. The Paste
button is unaffected: it claims whatever the person pastes, whenever they tap it.

**Turning device matching off:** Dashboard → Settings → **Device matching
(primary)**. When it is off, Strait stores no device signals at the tap, erases
the ones already stored for the workspace, and iPhone installs are only matched
through paste handoff (if on). Android installs keep
using the Play Install Referrer.

### Store sheet (beta; iPhone is beta)

When a user taps **Install** for one of your other apps (a sibling, partner or
"lite" app), show the App Store *inside your app* and keep the deep link for the
app being installed.

```swift
strait.openStoreSheet(
    url: "https://<handle>.strait.link/promo",
    options: StoreSheetOptions(style: .productPage), // or .overlay (SKOverlay, iOS 14+)
    presenter: SystemStoreSheetPresenter(from: viewController)
) { result in
    // result.opened, result.method ("product_page" | "overlay" | "none"), result.reason
}
```

What it does:

1. `POST /v1/store-sheet` records the tap (`sent_to = store_sheet`, not billed
   during the beta) and returns the App Store id and the link's campaign, sent
   as the `ct` campaign token.
2. Unless the workspace turned iPhone install matching off, it saves this
   device's match fields for that tap (`POST /v1/match-save`). The installed
   app's normal deferred check finds it. iPhone matching is beta.
3. With `copyHandoffLink: true` and the workspace's clipboard boost on, it also
   copies the one-time handoff link; an installed app with `clipboardBoost: true`
   claims it for an exact match. Off by default, because it replaces what the
   user had copied.
4. It shows `SKStoreProductViewController` (the full product page as a sheet)
   or `SKOverlay`. Pass `providerToken` / `customProductPageId` if you use them.

It works only where your app is the host. A link tapped inside another
company's app can't open a store sheet there. Offline, pass `appStoreId` to
still show the store (the deep link is not kept then, `reason = "offline"`).

### `LinkEvent`

`id` · `kind` (`direct` / `deferred`) · `route` (`app_link`, `custom_scheme`,
`fingerprint`, `clipboard`) · `appState` (`closed`, `background`, `foreground`) · `matched` ·
`reason` (`not_found`, `expired`, `password_protected`, `no_match`, `network`,
`invalid_url`, `not_handoff`, `handoff_unknown`, `handoff_used`, `handoff_expired`) · `rawUrl` · `url` · `path` · `params` · `linkId` · `ms` · `at` · `referralCode` (deferred links only: the referral code the tap carried, when the engine sends one; referrals are a preview and not switched on yet, contract B21; grant rewards from your server via the `referral.converted` webhook).
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

## Support

- **Stuck on install or a link that opens the browser?** Start with
  [Troubleshooting](https://straitlink.in/docs/troubleshooting/) and the free
  [App Links / AASA checker](https://straitlink.in/tools/).
- **Email:** [support@straitlink.in](mailto:support@straitlink.in). Include your
  workspace handle, the SDK version (see CHANGELOG.md), the iOS version and the
  link you tapped. Replies within 1 working day, IST.
- **Bugs and feature requests:** open an issue on this repository.
- **Security issues:** report privately to security@straitlink.in, never in a
  public issue (see SECURITY.md).
- **Service status:** [status.strait.link](https://status.strait.link).
