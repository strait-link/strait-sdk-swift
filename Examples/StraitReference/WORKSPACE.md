# Strait workspace settings for this build (written by set-team.sh)

| | |
|---|---|
| Apple Team ID | `C3L6B5HJU7` |
| App bundle ID | `in.straitlink.reference` |
| App Clip bundle ID (beta) | `in.straitlink.reference.Clip` |
| App Group | `group.in.straitlink.reference` |
| Link host (associated domain) | `strait-dev.strait.link` |
| URL scheme | `straitref://` |

## 1. Dashboard -> Settings -> App configuration (workspace on `strait-dev.strait.link`)

- Apple Team ID: `C3L6B5HJU7`
- Bundle ID: `in.straitlink.reference`
- App Store ID: the reference app's Apple ID from App Store Connect (App Information), once the app record exists
- App Clip bundle ID (shown after migration 0062 is applied, only for the App Clip run): `in.straitlink.reference.Clip`

Save. The engine serves the new file within its 10-minute cache.

## 2. Check what the engine serves

```
curl -sS -D - https://strait-dev.strait.link/.well-known/apple-app-site-association -o /tmp/aasa.json
python3 -m json.tool /tmp/aasa.json
```

Expected: `HTTP 200`, `content-type: application/json`, no `location` header, and

```json
{"applinks":{"apps":[],"details":[{"appIDs":["C3L6B5HJU7.in.straitlink.reference"],"components":[{"/":"/","exclude":true}, "...Strait paths excluded...", {"/":"/*","comment":"Every Strait link on this host"}],"appID":"C3L6B5HJU7.in.straitlink.reference","paths":["NOT /", "...", "*"]}]}}
```

(plus `"appclips":{"apps":["C3L6B5HJU7.in.straitlink.reference.Clip"]}` when the App Clip bundle ID is set). Apple's CDN copy:

```
curl -sS https://app-site-association.cdn-apple.com/a/v1/strait-dev.strait.link
```

## 3. Build, run, prove

```
cp Config/Local.xcconfig.example Config/Local.xcconfig   # put the st_pub_ key in it
scripts/generate.sh && open StraitReference.xcodeproj     # Xcode signs with team C3L6B5HJU7
scripts/device-proof.sh                                   # XCUITest on the connected iPhone
```
