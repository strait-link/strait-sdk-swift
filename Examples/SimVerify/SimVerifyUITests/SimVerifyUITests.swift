import UIKit
import XCTest

/// Drives Safari + the app on a simulator against a real Strait workspace.
/// Needs TEST_RUNNER_STRAIT_ENDPOINT, TEST_RUNNER_STRAIT_PK and TEST_RUNNER_STRAIT_LINK
/// (a short link on that workspace). The clipboard tests need the workspace's
/// "Clipboard boost" on (TEST_RUNNER_STRAIT_BOOST_ON=1).
final class SimVerifyUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var shots: String { env["STRAIT_SHOTS"] ?? NSTemporaryDirectory() }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(env["STRAIT_LINK"] == nil, "STRAIT_LINK not set")
    }

    private func app(reset: Bool, boost: Bool) -> XCUIApplication {
        let a = XCUIApplication()
        a.launchEnvironment["STRAIT_ENDPOINT"] = env["STRAIT_ENDPOINT"]
        a.launchEnvironment["STRAIT_PK"] = env["STRAIT_PK"]
        if reset { a.launchEnvironment["STRAIT_RESET"] = "1" }
        if boost { a.launchEnvironment["STRAIT_BOOST"] = "1" }
        return a
    }

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: shots).appendingPathComponent("\(name).png"))
    }

    /// Opens the short link in Safari and taps "Get the app" (the gesture that
    /// saves the device signature and, with the boost on, copies the handoff link).
    private func tapGetTheApp(_ name: String) {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.terminate()
        safari.launch()
        // First-run sheets on a fresh simulator.
        for label in ["Continue", "Not Now", "Close"] where safari.buttons[label].waitForExistence(timeout: 2) {
            safari.buttons[label].tap()
        }
        dismissStalePrompts()
        XCUIDevice.shared.system.open(URL(string: env["STRAIT_LINK"]!)!)
        let get = safari.links["Get the app"]
        XCTAssertTrue(get.waitForExistence(timeout: 20), "tap page did not show Get the app")
        shot("\(name)-1-tap-page")
        get.tap()
        sleep(3) // match-save (keepalive) + clipboard write before Safari navigates to the App Store
        shot("\(name)-2-after-get-app")
    }

    private func waitForEvent(_ a: XCUIApplication, containing s: String, timeout: TimeInterval = 20) -> String {
        let last = a.staticTexts["lastEvent"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if last.exists, last.label.contains(s) { return last.label }
            usleep(300_000)
        }
        return last.exists ? last.label : "missing"
    }

    /// A leftover "Open in …?" prompt would eat the "Get the app" tap.
    private func dismissStalePrompts() {
        let cancel = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Cancel"]
        while cancel.waitForExistence(timeout: 1) { cancel.tap() }
    }

    /// Opens a URL the way `simctl openurl` does and accepts iOS's "Open in …?" prompt.
    private func openURL(_ s: String) {
        XCUIDevice.shared.system.open(URL(string: s)!)
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 5) { open.tap() }
    }

    /// Direct custom-scheme links: warm (app on screen) and cold (app killed).
    func test0_DirectCustomScheme() throws {
        let a = app(reset: false, boost: false)
        a.launch()
        _ = waitForEvent(a, containing: "kind=", timeout: 8) // let any first-launch check finish
        openURL("straitsim://example.com/product/42?color=red&strait_click=0f8fbc5e-1b7a-4c1e-9a77-1d2b3c4d5e6f")
        var label = waitForEvent(a, containing: "kind=direct")
        shot("direct-1-warm")
        XCTAssertTrue(label.contains("route=custom_scheme"), label)
        XCTAssertTrue(label.contains("state=foreground"), label)
        XCTAssertTrue(label.contains("matched=true reason=- path=/product/42 params=color=red linkId"), label) // strait_click removed

        a.terminate()
        openURL("straitsim://example.com/cart?item=7")
        label = waitForEvent(a, containing: "path=/cart")
        shot("direct-2-cold")
        XCTAssertTrue(label.contains("kind=direct route=custom_scheme"), label)
        // Documented SwiftUI limitation (README "SwiftUI"): the cold-launch URL arrives
        // via onOpenURL, so it is labelled by app state, not `closed`.
        XCTAssertTrue(label.contains("state=foreground"), label)
        XCTAssertTrue(label.contains("params=item=7"), label)
    }

    /// iPhone install matching (fingerprint): Safari tap → first app launch matches.
    func test1_DeferredSignalMatch() throws {
        tapGetTheApp("deferred-match")
        let a = app(reset: true, boost: false)
        a.launch()
        let label = waitForEvent(a, containing: "kind=deferred")
        shot("deferred-match-3-app")
        XCTAssertTrue(label.contains("route=fingerprint"), label)
        XCTAssertTrue(label.contains("matched=true"), label)
        XCTAssertTrue(label.contains("path=/product/42"), label)
        XCTAssertTrue(label.contains("params=color=red"), label)
    }

    /// A handoff link that was never minted (22 base64url chars) on the workspace host.
    /// Used when the workspace's clipboard boost is off, so no real handoff exists.
    private func strayHandoff() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let token = String((0..<22).map { _ in chars.randomElement()! })
        return "\(env["STRAIT_ENDPOINT"]!)/h/\(token)"
    }

    /// Clipboard boost on the once-per-install check: detect (no prompt), read
    /// ("Allow Paste"), claim. Boost on: the tap page's real handoff link must
    /// match exactly. Boost off: a never-minted handoff link is put on the
    /// clipboard; the engine refuses it and the SDK must fall back to the signal
    /// match of the Safari tap (same openId).
    func test2_ClipboardBoostAutoClaim() throws {
        let boostOn = env["STRAIT_BOOST_ON"] == "1"
        tapGetTheApp("clipboard-auto")
        if !boostOn { UIPasteboard.general.string = strayHandoff() }
        let a = app(reset: true, boost: true)
        a.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow Paste"]
        let prompted = allow.waitForExistence(timeout: 10)
        if prompted {
            shot("clipboard-auto-3-paste-prompt")
            allow.tap()
        }
        let label = waitForEvent(a, containing: "kind=deferred")
        shot("clipboard-auto-4-app")
        XCTAssertTrue(prompted, "iOS paste prompt never appeared: the SDK did not read the clipboard")
        XCTAssertTrue(label.contains(boostOn ? "route=clipboard" : "route=fingerprint"), label)
        XCTAssertTrue(label.contains("matched=true"), label)
        XCTAssertTrue(label.contains("path=/product/42"), label)
    }

    /// Apple's Paste button (no prompt) claims a handoff link after the first launch.
    func test3_PasteButtonClaim() throws {
        let boostOn = env["STRAIT_BOOST_ON"] == "1"
        let a = app(reset: false, boost: false)
        a.launch() // deferred check already done by earlier tests: nothing runs
        if boostOn { tapGetTheApp("paste-button") } else { UIPasteboard.general.string = strayHandoff() }
        a.activate()
        let paste = a.descendants(matching: .any)["straitPaste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 10))
        shot("paste-button-3-app-before")
        paste.tap()
        let label = waitForEvent(a, containing: "route=clipboard")
        shot("paste-button-4-app-after")
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"].exists, "Paste button must not prompt")
        if boostOn {
            XCTAssertTrue(label.contains("matched=true"), label)
            XCTAssertTrue(label.contains("path=/product/42"), label)
        } else {
            // Reached the engine: a never-minted token is refused as handoff_unknown.
            XCTAssertTrue(label.contains("matched=false reason=handoff_unknown"), label)
        }
    }
}
