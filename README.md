# StraitSDK (iOS / Swift)

Deferred deep linking for native iOS — the user taps your link, installs, and
lands on the right screen. No clipboard paste banner.

Part of [Strait](../). The match signature is a Swift port kept in lockstep with
the server and every other SDK via [`shared-spec`](../shared-spec) golden vectors
(run by `swift test` in CI). 32-bit hash overflow is matched with `Int32` + `&*`.

> ⚠️ Verified by CI (`swift test` on macOS) against the golden vectors. Wire-up
> into a real app + on-device deferred-install verification still needs Xcode.

## Install (Swift Package Manager)

```swift
.package(url: "https://github.com/bazingga08/strait-sdk-swift", from: "0.1.0")
```

## Use

```swift
import StraitSDK

let result = await Strait.resolveDeferredLink(
    StraitConfig(appId: "YOUR_APP_ID", endpoint: "https://go.yourbrand.com")
)
if result.matched, let url = result.longUrl {
    // route to url
}
```

Collects only coarse device fields (screen width, scale, language, timezone);
the **server** adds the observed IP and computes the match signature.
