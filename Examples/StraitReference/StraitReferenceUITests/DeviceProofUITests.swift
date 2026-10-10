import UIKit
import XCTest

/// The real-iPhone proof (scripts/device-proof.sh runs it). Needs a signed
/// build on a connected iPhone and these TEST_RUNNER_* variables (xcodebuild
/// strips the prefix):
///   STRAIT_ENDPOINT  https://<handle>.strait.link (the host in Config/Team.xcconfig)
///   STRAIT_PK        the workspace's publishable key (st_pub_…)
///   STRAIT_LINK      a short link on that host, e.g. https://<host>/bl-product
///   STRAIT_LINK_PATH the path its destination opens (default /p/42)
///   STRAIT_EXPECT_DEVICE / STRAIT_EXPECT_PASTE  "1" or "0": the dashboard
///                    switches you set for this run (test05/test06; unset = skip)
/// Screenshots are XCTAttachments kept in the .xcresult; the script exports them.
final class DeviceProofUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private lazy var link = env["STRAIT_LINK"] ?? ""
    /// The path the link's destination opens (strait-dev's bl-product -> /p/42?color=red).
    private lazy var linkPath = env["STRAIT_LINK_PATH"] ?? "/p/42"
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(env["STRAIT_ENDPOINT"] == nil || env["STRAIT_PK"] == nil, "STRAIT_ENDPOINT / STRAIT_PK not set")
    }

    // MARK: helpers

    private func app(reset: Bool = false) -> XCUIApplication {
        let a = XCUIApplication()
        a.launchEnvironment["STRAIT_ENDPOINT"] = env["STRAIT_ENDPOINT"]
        a.launchEnvironment["STRAIT_PK"] = env["STRAIT_PK"]
        if reset { a.launchEnvironment["STRAIT_RESET"] = "1" }
        return a
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func note(_ name: String, _ text: String) {
        let a = XCTAttachment(string: text)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func label(_ a: XCUIApplication, _ id: String) -> String {
        let e = a.descendants(matching: .any)[id]
        return e.exists ? e.label : "missing"
    }

    /// Waits until the newest event contains `s` (or times out) and returns it.
    private func waitForEvent(_ a: XCUIApplication, containing s: String, timeout: TimeInterval = 25) -> String {
        a.tabBars.buttons["Links"].tapIfHittable()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let v = label(a, "lastEvent")
            if v.contains(s) { return v }
            usleep(300_000)
        }
        return label(a, "lastEvent")
    }

    private func requireLink() throws {
        try XCTSkipIf(link.isEmpty, "STRAIT_LINK not set")
    }

    /// Opens a URL the way another app does (Mail, Messages, Notes all call
    /// openURL): a Universal Link opens the claiming app directly.
    private func openFromOtherApp(_ s: String) {
        XCUIDevice.shared.system.open(URL(string: s)!)
        // A custom scheme opened from outside may ask "Open in “Strait Ref”?".
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 3) { open.tap() }
    }

    /// Loads a URL in Safari by TYPING it (typed URLs never trigger Universal
    /// Links), so the Strait tap page shows even with the app installed.
    private func loadInSafari(_ s: String) throws {
        safari.terminate()
        safari.launch()
        for b in ["Continue", "Not Now", "Close"] where safari.buttons[b].waitForExistence(timeout: 1.5) { safari.buttons[b].tap() }
        let candidates: [XCUIElement] = [
            safari.textFields["TabBarItemTitle"], safari.buttons["TabBarItemTitle"],
            safari.otherElements["TabBarItemTitle"], safari.textFields["Address"], safari.buttons["Address"],
        ]
        guard let field = candidates.first(where: { $0.waitForExistence(timeout: 2) }) else {
            throw XCTSkip("Safari's address bar was not found on this iOS version: do this step by hand (MANUAL-STEPS in the test plan)")
        }
        field.tap()
        let input = safari.textFields.element(boundBy: 0)
        _ = input.waitForExistence(timeout: 3)
        input.typeText(s + "\n")
    }

    // MARK: 1. what Strait says right now

    func test01_RuntimeChoiceIsLive() throws {
        let a = app()
        a.launch()
        a.tabBars.buttons["Settings"].tap()
        a.buttons["askStrait"].tap()
        let summary = a.staticTexts["runtimeSummary"]
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, ["Not asked yet", "Asking…"].contains(summary.label) { sleep(1) }
        shot("01-runtime-choice")
        note("01-runtime-choice", "\(summary.label) device=\(label(a, "runtimeDeviceMatching")) paste=\(label(a, "runtimePasteHandoff"))")
        XCTAssertNotEqual(summary.label, "Not asked yet", "Strait never answered /v1/match")
        XCTAssertFalse(summary.label.hasPrefix("Strait answered without"), "the engine must carry ios:{deviceMatching,pasteHandoff} (engine 4f5ea06+): \(summary.label)")
        XCTAssertFalse(summary.label.hasPrefix("Strait could not"), summary.label)
        if let d = env["STRAIT_EXPECT_DEVICE"] { XCTAssertEqual(label(a, "runtimeDeviceMatching"), d == "1" ? "on" : "off") }
        if let p = env["STRAIT_EXPECT_PASTE"] { XCTAssertEqual(label(a, "runtimePasteHandoff"), p == "1" ? "on" : "off") }
    }

    // MARK: 2. the AASA names this signed app

    func test02_AASAListsThisApp() throws {
        let a = app()
        a.launch()
        a.tabBars.buttons["Settings"].tap()
        let appId = label(a, "appId")
        try XCTSkipIf(appId.hasPrefix("unsigned"), "unsigned build: no App ID to compare")
        a.buttons["checkAasa"].tap()
        let result = a.staticTexts["aasaResult"]
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !result.exists || result.label.hasPrefix("Fetching") { usleep(300_000) }
        shot("02-aasa")
        note("02-aasa", result.label)
        XCTAssertTrue(result.label.contains("HTTP 200 application/json"), result.label)
        XCTAssertTrue(result.label.contains("this app: listed"), result.label)
        XCTAssertFalse(result.label.contains("Redirected"), result.label)
    }

    // MARK: 3-4. Universal Links: warm (background, foreground) and cold

    func test03_UniversalLinkWarm() throws {
        try requireLink()
        let a = app()
        a.launch()
        _ = waitForEvent(a, containing: "kind=", timeout: 8) // let a first-launch check finish

        // Foreground: the app is on screen.
        openFromOtherApp(link)
        var e = waitForEvent(a, containing: "route=app_link")
        shot("03a-universal-foreground")
        note("03a-universal-foreground", e)
        XCTAssertTrue(e.contains("kind=direct route=app_link"), "the link did not open the app as a Universal Link: \(e)")
        XCTAssertTrue(e.contains("matched=true"), e)
        XCTAssertTrue(e.contains("path=\(linkPath)"), e)

        // Background: home screen, then the link.
        XCUIDevice.shared.press(.home)
        sleep(3)
        openFromOtherApp(link + (link.contains("?") ? "&" : "?") + "ref_run=bg")
        XCTAssertTrue(a.wait(for: .runningForeground, timeout: 15), "the app did not come to the foreground")
        e = waitForEvent(a, containing: "ref_run=bg")
        shot("03b-universal-background")
        note("03b-universal-background", e)
        XCTAssertTrue(e.contains("route=app_link state=background"), e)
    }

    func test04_UniversalLinkCold() throws {
        try requireLink()
        let a = app()
        a.launch()
        a.terminate()
        openFromOtherApp(link)
        XCTAssertTrue(a.wait(for: .runningForeground, timeout: 20), "the link did not launch the app")
        let e = waitForEvent(a, containing: "route=app_link")
        shot("04-universal-cold")
        note("04-universal-cold", e)
        XCTAssertTrue(e.contains("kind=direct route=app_link state=closed matched=true"), e)
        XCTAssertEqual(label(a, "launchSource"), "universal link")
    }

    // MARK: 5. deferred link for the dashboard combination under test

    /// Safari tap page -> "Get the app" -> the app's once-per-install check
    /// (STRAIT_RESET=1 forgets the first launch; a TestFlight reinstall is the
    /// real "not installed" run, see the test plan). Asserts what the dashboard
    /// combination promises.
    func test05_DeferredForThisCombination() throws {
        try requireLink()
        guard let d = env["STRAIT_EXPECT_DEVICE"], let p = env["STRAIT_EXPECT_PASTE"] else {
            throw XCTSkip("set STRAIT_EXPECT_DEVICE and STRAIT_EXPECT_PASTE to the dashboard switches")
        }
        let device = d == "1", paste = p == "1"
        let combo = "device-\(device ? "on" : "off")-paste-\(paste ? "on" : "off")"
        try loadInSafari(link)
        let get = safari.links["Get the app"].firstMatch
        XCTAssertTrue(get.waitForExistence(timeout: 25), "the tap page did not show Get the app")
        shot("05-\(combo)-1-tap-page")
        get.tap()
        sleep(3) // match-save (keepalive) and the handoff copy before Safari leaves for the App Store
        shot("05-\(combo)-2-after-get-app")

        let a = app(reset: true)
        a.launch()
        let allow = springboard.buttons["Allow Paste"]
        let prompted = allow.waitForExistence(timeout: device ? 6 : 10)
        if prompted {
            shot("05-\(combo)-3-paste-prompt")
            allow.tap()
        }
        let e = waitForEvent(a, containing: "kind=deferred")
        shot("05-\(combo)-4-app")
        note("05-\(combo)", "prompted=\(prompted) \(e)")
        switch (device, paste) {
        case (true, _):
            // Device matching first; the clipboard is read only when it finds nothing.
            XCTAssertTrue(e.contains("matched=true"), e)
            XCTAssertTrue(e.contains("route=fingerprint") || (paste && e.contains("route=clipboard")), e)
            XCTAssertTrue(e.contains("path=\(linkPath)"), e)
        case (false, true):
            XCTAssertTrue(prompted, "paste handoff on: iOS should have asked to paste")
            XCTAssertTrue(e.contains("route=clipboard"), e)
            XCTAssertTrue(e.contains("matched=true"), e)
            XCTAssertTrue(e.contains("path=\(linkPath)"), e)
        case (false, false):
            XCTAssertFalse(prompted, "both off: the clipboard must not be touched")
            XCTAssertTrue(e.contains("matched=false reason=no_match"), e)
        }
    }

    // MARK: 6. Apple's Paste button (no prompt)

    func test06_PasteButtonClaimsHandoff() throws {
        try requireLink()
        try XCTSkipIf(env["STRAIT_EXPECT_PASTE"] != "1", "needs paste handoff on (STRAIT_EXPECT_PASTE=1)")
        try loadInSafari(link)
        let get = safari.links["Get the app"].firstMatch
        XCTAssertTrue(get.waitForExistence(timeout: 25))
        get.tap()
        sleep(3)
        let a = app()
        a.launch()
        a.tabBars.buttons["Paste"].tap()
        let paste = a.descendants(matching: .any)["straitPaste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 10))
        paste.tap()
        let e = waitForEvent(a, containing: "route=clipboard")
        shot("06-paste-button")
        note("06-paste-button", e)
        XCTAssertFalse(springboard.buttons["Allow Paste"].exists, "the Paste button must not prompt")
        XCTAssertTrue(e.contains("matched=true"), e)
    }

    // MARK: 7. store sheet inside the app

    func test07_StoreSheet() throws {
        try requireLink()
        let a = app()
        a.launch()
        a.tabBars.buttons["Store sheet"].tap()
        let field = a.textFields["storeLink"]
        field.tap()
        field.clearAndType(link)
        a.buttons["storeProductPage"].tap()
        sleep(6) // the App Store product page loads inside the app
        shot("07-store-sheet")
        // Dismiss the sheet (its Done/Cancel button) to read the result.
        for b in ["Done", "Cancel", "Close"] where a.buttons[b].waitForExistence(timeout: 2) { a.buttons[b].tap(); break }
        let result = a.staticTexts["storeResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        note("07-store-sheet", result.label)
        XCTAssertTrue(result.label.contains("opened=true method=product_page"), result.label)
    }

    // MARK: 8. custom-scheme fallback

    func test08_CustomSchemeFallback() throws {
        let a = app()
        a.launch()
        _ = waitForEvent(a, containing: "kind=", timeout: 8)
        openFromOtherApp("straitref://example.com/product/42?color=red")
        let e = waitForEvent(a, containing: "route=custom_scheme")
        shot("08-custom-scheme")
        note("08-custom-scheme", e)
        XCTAssertTrue(e.contains("kind=direct route=custom_scheme"), e)
        XCTAssertTrue(e.contains("path=/product/42 params=color=red"), e)
    }
}

private extension XCUIElement {
    func tapIfHittable() { if exists && isHittable { tap() } }

    func clearAndType(_ text: String) {
        if let current = value as? String, !current.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        typeText(text)
    }
}
