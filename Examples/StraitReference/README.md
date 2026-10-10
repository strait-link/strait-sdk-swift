# StraitReference: the signable iOS reference app (beta)

A real iOS app wired to StraitSDK from this repo, ready for a physical iPhone,
TestFlight and an optional App Clip. iPhone support stays **beta** until the
real-device proof below has passed.

<!-- set-team:values -->
Team: placeholder (not set) · app `in.straitlink.reference` · host `strait-dev.strait.link` (set with `scripts/set-team.sh`)
<!-- /set-team:values -->

What it shows:

| Screen | What it proves |
|---|---|
| Links | Universal Links (`applinks:<host>`), warm and cold (UIKit scenes, so a cold start is labelled `closed`), the `straitref://` custom-scheme fallback, the App Clip handoff, every `LinkEvent` |
| Store sheet | `openStoreSheet`: `SKStoreProductViewController` or `SKOverlay` inside the app, the tap recorded and the deep link kept |
| Paste | Apple's Paste button (`StraitPasteButton`, no prompt) and the no-prompt clipboard check |
| Settings | The **live runtime choice** from Strait's `/v1/match` reply (device matching / paste handoff, set in Dashboard → Settings → iPhone installs), this build's App ID and associated domain, and a direct check that the workspace AASA lists this app |

Look: the Strait design system (v5), light and dark, from the SDK's generated `StraitTokens`
(`StraitReference/StraitTheme.swift`): warm grounds and card surfaces instead of the system's
cool greys, buttons and links in brand-text (`#B84200` light, `#FF8237` dark), the orange fill
only for the one primary action (the Paste button, the App Clip's "Get the full app"), system
fonts and no motion of its own.

## One-time setup (when the Apple team exists)

```sh
scripts/set-team.sh <TEAM_ID> <BUNDLE_PREFIX> [<link host>]   # e.g. ABCDE12345 in.straitlink strait-dev.strait.link
cp Config/Local.xcconfig.example Config/Local.xcconfig          # STRAIT_PUBLISHABLE_KEY = st_pub_…
```

`set-team.sh` writes `Config/Team.xcconfig`, regenerates the project, refreshes
the block above and writes `WORKSPACE.md` with the exact Dashboard settings
(Apple Team ID, bundle ID `<prefix>.reference`, App Clip `<prefix>.reference.Clip`)
and the AASA the engine must then serve. It refuses the employer's team.

## Commands

| Command | Needs | Does |
|---|---|---|
| `scripts/generate.sh` | xcodegen | `project.yml` → `StraitReference.xcodeproj` |
| `STRAIT_APP_CLIP=1 scripts/generate.sh` | | the same plus the App Clip target (`project-appclip.yml`) |
| `scripts/build-device.sh` | nothing (placeholder team) | builds for a generic iOS device with signing off: the CI gate |
| `scripts/device-proof.sh` | team, Xcode account, iPhone in Developer Mode | XCUITest on the phone: runtime choice, AASA, Universal Links warm/cold, store sheet, scheme, then the four dashboard combinations (it pauses for you to flip the switches) |
| `scripts/testflight.sh` | team, Xcode account, App Store Connect app record | archive + `xcodebuild -exportArchive` upload (internal testing only) |

## The App Clip (beta, behind `STRAIT_APP_CLIP=1`)

A link on the workspace host opens the App Clip with the exact URL. The App Clip
saves it in the App Group `group.<prefix>.reference` (`StraitAppClip.saveInvocation`)
and offers the full app (`SKOverlay.AppClipConfiguration`). On the full app's
first launch, `StraitAppClip.takeInvocation` returns that URL once and the app
passes it to `start(initialURL:)`: an exact deferred deep link, no device matching,
no clipboard. Apple shares an App Group container between an App Clip and its
full app, and its contents carry over when the full app replaces the App Clip.

For the engine to list the App Clip in the AASA (`appclips`), set the App Clip
bundle ID in Dashboard → Settings → App configuration (needs migration 0062).
Test without the App Store: iPhone Settings → Developer → Local Experiences
(register `https://<host>/` for the App Clip bundle ID), or TestFlight's App
Clip invocations. A link only shows the App Clip card when iOS knows the
experience (Local Experience, App Store Connect App Clip experience, or a
Smart App Banner); otherwise it opens the full app or the web page.

The full real-iPhone checklist (cold/warm, installed/not installed via TestFlight, the four dashboard combinations, WhatsApp/Instagram, App Clip) is [TEST-PLAN.md](TEST-PLAN.md).

## Notes

- Universal Links never fire for a typed URL or a link to the same host the
  page is on; the proof opens links from another app (`openURL`, like Notes or
  Messages) and loads the tap page by typing it in Safari.
- If someone picks "Open in Safari" from the Universal Link banner, iOS stops
  opening that host in the app until they choose "Open in Strait Ref" again.
- Debug builds also claim `applinks:<host>?mode=developer`: with Settings →
  Developer → Associated Domains Development on, the phone reads the AASA
  directly instead of waiting for Apple's CDN.
