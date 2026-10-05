# AGENTS.md: Strait iOS SDK (StraitSDK, Swift Package)

Instructions for AI coding agents (Claude Code, Cursor, Codex, Copilot…) that add this SDK to an app or work on
this repo. Humans: see README.md.

Swift Package for iPhone and iPad apps. iPhone install matching (deferred deep links on iOS) is in **beta**: say so to the user.

## Install

Swift Package Manager: `https://github.com/bazingga08/strait-sdk-swift`, version 0.8.0 or later.

```swift
.package(url: "https://github.com/bazingga08/strait-sdk-swift", from: "0.8.0")
// target dependency: .product(name: "StraitSDK", package: "strait-sdk-swift")
```

Xcode: Signing & Capabilities → Associated Domains → `applinks:<handle>.strait.link`, and the custom scheme under
Info → URL Types. The Apple Team ID and bundle ID must be saved in Dashboard → Settings.

## Keys (the rule agents get wrong most)

- **Publishable key** `st_pub_live_…` (Dashboard → Get started): goes in the app. It is the only key this SDK takes (`publishableKey`).
- **Secret key** `st_live_…` (Dashboard → Settings → Secret keys): server only. Never put it in an app: anyone can extract it and change your links.
- Never commit either key's real value to this repo, tests or examples. Use placeholders like `st_pub_live_…`.

## Receive links: the one pattern

```swift
import StraitSDK

let links = StraitLinks(StraitLinksConfig(
    publishableKey: "st_pub_live_…",     // never the secret key
    endpoint: "https://acme.strait.link"     // the workspace's link domain
))
links.onLink { event in                  // replays past events
    guard event.matched, let path = event.path else { return }
    router.open(path, params: event.params ?? [:])
}
```

- Scenes: `links.start(initialURL:)` in `scene(_:willConnectTo:options:)` with the launch URL,
  `links.handle(userActivity:)` in `scene(_:continue:)`, `links.handle(url:)` in `scene(_:openURLContexts:)`.
- SwiftUI: `init() { links.start() }`, then `.onOpenURL { links.handle(url: $0) }` and
  `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { links.handle(userActivity: $0) }`.

## Verify

Run these; don't assume.

```sh
# 1. The link domain serves the verification files with this app in them
curl https://<handle>.strait.link/.well-known/assetlinks.json              # Android: package + every SHA-256
curl https://<handle>.strait.link/.well-known/apple-app-site-association   # iPhone: TeamID.bundleId
#    (or the free checker: https://straitlink.in/tools/  ·  MCP tool: check_app_links)

# 2. Android verified the host (fresh install). Want: verified
adb shell pm get-app-links <package.name>   # Android only; on iPhone, long-press the link: "Open in <app>" means it verified
```

3. Tap a link from WhatsApp or Gmail on a real phone: the app opens on the right screen and `onLink` fires
   with `matched: true`. The tap and the open appear in Dashboard → Analytics.
4. Deferred (iPhone, beta): delete the app, tap the link in Safari, then install your build and open it: `onLink`
   fires with `kind == .deferred` and `route == .fingerprint` (`.clipboard` with the clipboard boost). iPhone
   install matching is in beta.

If links open the browser: a missing SHA-256 (most often the Play App Signing key from Play Console → App
integrity), a typo in the host, or the app was installed before the files were right (reinstall). See
https://straitlink.in/docs/troubleshooting/.

## Working on this repo

- Test: `swift build && swift test   # macOS with Xcode (XCTest)` (must pass before any commit; check the exit code).
- The match signature and the pure helpers are pinned by shared golden vectors
  (`Tests/**/*vectors*.json`): byte-identical copies live in every SDK (the signature vectors also in the engine). Never edit a vector file
  here alone; vectors change only through `shared-spec/` and land in every repo together.
- The package's public identity (name, scope, owner, domain) lives only in `brand.json`; change it with
  `shared-spec/scripts/rename-brand.sh` (all SDKs) or `node scripts/brand.mjs --write`.
- Wire names are part of the contract: query params `strait_click` / `strait_link`, storage keys `strait.*`,
  headers `X-Strait-*`. Don't rename them.
- Brand: Strait (never "Straight"). Don't write superlatives ("best", "cheapest") or speed / match-rate numbers in
  docs or comments. iPhone install matching is in beta.

## More

- Docs for this SDK: https://straitlink.in/docs/sdks/ios/
- All docs: https://straitlink.in/docs/ · REST API: https://straitlink.in/docs/api/
- Strait from AI tools (MCP server: create links, check App Links files, trace taps): https://straitlink.in/ai/
