# Real-iPhone test plan (StraitReference)

iPhone stays **beta** until every row marked **gate** passes on a real iPhone.
Each row lists how it runs: **auto** (`scripts/device-proof.sh`, XCUITest on the
connected phone, screenshots in `proof/<time>/*-shots/`) or **manual** (do it by
hand and take a screenshot with side button + volume up; name it as given).

Preconditions (once):

- [ ] `scripts/set-team.sh <TEAM_ID> <BUNDLE_PREFIX>` done; `Config/Local.xcconfig` has the `st_pub_` key.
- [ ] Dashboard → Settings → App configuration for the workspace on the host: Team ID + bundle ID from `WORKSPACE.md`.
- [ ] Engine with the runtime choice (`/v1/match` reply carries `ios`, engine 4f5ea06+) and the new AASA format (36e67f6+) is deployed. Until then test01 fails with "Strait answered without the iPhone choice".
- [ ] `curl -sD - https://<host>/.well-known/apple-app-site-association` → 200, `application/json`, no `location`, `appIDs` = `TEAMID.<prefix>.reference`.
- [ ] iPhone: Developer Mode on (Settings → Privacy & Security → Developer Mode), unlocked, trusted this Mac; Settings → Developer → Associated Domains Development on (Debug builds then read the AASA directly, no CDN wait).
- [ ] A link on the host: default `https://<host>/bl-product` → `https://example.com/p/42?color=red` (strait-dev). Another workspace: set `STRAIT_LINK` and `STRAIT_LINK_PATH`.
- [ ] Paste a copy of the link into a Note (Notes app) and send it to yourself in Messages and WhatsApp, for the manual taps.

## A. Installed app (Xcode / device-proof build)

| # | Case | How | Expected (last event on the Links tab) | |
|---|---|---|---|---|
| A1 | Runtime choice is live | auto test01 | Settings shows one of the four combinations, matching the dashboard | gate |
| A2 | AASA lists this signed app | auto test02 | `HTTP 200 application/json`, `this app: listed`, no redirect | gate |
| A3 | Universal Link, app in foreground | auto test03 | `kind=direct route=app_link state=foreground matched=true path=/p/42` | gate |
| A4 | Universal Link, app in background | auto test03 | `route=app_link state=background` | gate |
| A5 | Universal Link, app closed (cold) | auto test04 | `route=app_link state=closed matched=true`, Launch link = universal link | gate |
| A6 | Real tap from Notes, cold and warm | manual `A6-notes-cold.png`, `A6-notes-warm.png` | the app opens directly (no Safari), same events as A3/A5 | gate |
| A7 | Real tap from Messages | manual `A7-messages.png` | the app opens directly | gate |
| A8 | Custom-scheme fallback | auto test08 | `route=custom_scheme path=/product/42 params=color=red` | |
| A9 | Store sheet, product page | auto test07 | `opened=true method=product_page`; the App Store page shows inside the app | gate |
| A10 | Store sheet, overlay | manual `A10-overlay.png` (Store sheet tab → Show overlay) | an SKOverlay card at the bottom; result `opened=true method=overlay` | |
| A11 | Universal Link self-check | manual (Links tab button) | "Claimed" | |
| A12 | "Open in Safari" opt-out | manual: long-press the link in Notes → Open in Safari, then tap again | iOS now opens Safari for this host; the banner's "Open" brings the app back. Document, not a failure | |

## B. Deferred link, each dashboard combination (installed build, first launch forgotten)

`device-proof.sh` pauses before each run: set Dashboard → Settings → iPhone
installs, press Enter. Each run types the link into Safari (typed URLs never open
the app), taps **Get the app**, then relaunches the app with the first launch
forgotten (`STRAIT_RESET=1`).

| # | Device matching | Paste handoff | Expected | |
|---|---|---|---|---|
| B1 | on | off | no paste prompt; `route=fingerprint matched=true path=/p/42` | gate |
| B2 | off | on | iOS "Allow Paste" prompt → Allow; `route=clipboard matched=true`; test06: Paste button claims with **no** prompt | gate |
| B3 | on | on | device match first: no prompt when it matches (`route=fingerprint`); if it misses, the prompt and `route=clipboard` | gate |
| B4 | off | off | no prompt; `matched=false reason=no_match` | gate |

## C. Not installed (TestFlight internal build, the real first install)

Delete the app before each row. Install from the TestFlight app after the tap.
(TestFlight is the App Store stand-in: the tap page's "Get the app" goes to the
workspace's App Store ID, so for these rows open TestFlight yourself after the tap.)

| # | Case | Steps | Expected | |
|---|---|---|---|---|
| C1 | Tap → install → first open, B1 setting | tap the link in Notes → Safari tap page → Get the app → TestFlight → Install → Open | Links tab: `kind=deferred route=fingerprint matched=true`; `C1.png` | gate |
| C2 | Same with B2 setting | as C1 | "Allow Paste" → `route=clipboard matched=true`; `C2.png` | gate |
| C3 | Same with B4 setting | as C1 | `matched=false reason=no_match`, no prompt; `C3.png` | gate |
| C4 | Change the dashboard choice with no new build | flip a switch, Settings → Ask Strait now | the Method row changes; `C4.png` | gate |
| C5 | Network change between tap and install | tap on Wi-Fi, install + open on cellular | record the result (device matching may miss; paste handoff should still match); `C5.png` | |
| C6 | iCloud Private Relay on | Settings → Apple Account → iCloud → Private Relay on, repeat C1 | record the result; `C6.png` | |

## D. In-app browsers (installed and not installed)

Send the link to yourself in each app and tap it there.

| # | App | Installed: expected | Not installed: expected | |
|---|---|---|---|---|
| D1 | WhatsApp | opens the app (WhatsApp hands https links to iOS) or Strait's in-app page with **Open in app**; `D1-installed.png` | Strait's page → Get the app; deferred as in C; `D1-not-installed.png` | gate |
| D2 | Instagram (DM or bio link) | Instagram's own browser: Strait's in-app page; **Open in app** opens the app via `straitref://` or the Universal Link; `D2-installed.png` | page → Get the app (may need "Open in Safari" first); record whether the deferred link survives; `D2-not-installed.png` | gate |
| D3 | Gmail / Telegram / Slack (optional) | record | record | |

## E. App Clip (only with `STRAIT_APP_CLIP=1`, beta)

Needs migration 0062 applied and the App Clip bundle ID saved in the dashboard
(the AASA then lists `appclips`). On the phone: Settings → Developer → App Clips
Testing → Local Experiences → Register: URL prefix `https://<host>/`, bundle ID
`<prefix>.reference.Clip`, any title.

| # | Case | Expected | |
|---|---|---|---|
| E1 | Full app NOT installed, tap the link in Messages | the App Clip card; open → the clip shows the link and "Saved for the full app"; `E1.png` | |
| E2 | From the clip, Get the full app → install (TestFlight) → open | Launch link = App Clip; `kind=direct route=app_link state=closed matched=true`; no paste prompt, no device match; `E2.png` | |
| E3 | Full app installed | the link opens the full app, not the clip | |

## Recording the result

Copy `proof/<time>/SUMMARY.txt` and the screenshots to
`strait/design-work/ios-verify/real-device-<date>/`, fill in this table there,
and only when every **gate** row passes, change the iPhone label from beta.
