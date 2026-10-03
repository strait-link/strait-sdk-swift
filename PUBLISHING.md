# Publishing (Swift Package Manager)

SwiftPM has no upload step: apps add the **git URL** and SwiftPM resolves semver
**tags** (`v0.4.0` and `0.4.0` both work). So a release = a pushed tag on a public repo.
The repo URL and copyright holder come from `brand.json`; `scripts/brand.mjs` writes
them into the README install block and LICENSE.

## One-time owner setup

1. **Pick the brand.** From the workspace root: `shared-spec/scripts/rename-brand.sh … --final --apply`.
   Rename/move the GitHub repo first if it will change — the URL *is* the package
   identity (`package: "<repo>"` in apps' manifests). GitHub redirects old URLs, but
   SwiftPM identity follows the last path component, so pick the final repo name
   before the first public tag.
2. **Make the GitHub repo public.**
3. Optional: submit the repo URL at https://swiftpackageindex.com/add-a-package for
   discoverability + hosted docs. Nothing else to configure.

## Every release

1. Add a `## X.Y.Z` entry to CHANGELOG.md, run `node scripts/brand.mjs --write`
   (moves the README's `from:` version to the newest changelog entry), commit.
2. `swift build && swift test` (tests need Xcode's XCTest; CI runs them on macOS).
3. `git tag vX.Y.Z && git push origin main vX.Y.Z`.
4. *Actions → Release* checks the changelog entry, builds in release mode and runs the
   tests on macOS. It also fails if `brand.json` is not final — never tag a public
   version under the placeholder brand (a published tag can't be taken back).

## Optional: CocoaPods

Only if customers ask for it. CocoaPods has announced its trunk goes read-only
(planned for December 2026), so SwiftPM is the path forward. It would need a `<Product>.podspec` generated
from `brand.json` and a `COCOAPODS_TRUNK_TOKEN` secret.
