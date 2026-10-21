import XCTest

/// Real-iPhone look at a homepage URL in Safari: finger-style swipes down and back up,
/// a screenshot after each, and a Replay tap. Set TEST_RUNNER_STRAIT_HOMEPAGE_URL.
final class SafariHomepageUITests: XCTestCase {
    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testHomepageTouchScroll() throws {
        let url = ProcessInfo.processInfo.environment["STRAIT_HOMEPAGE_URL"] ?? "https://straitlink.in/"
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        if #available(iOS 16.4, *) { safari.open(URL(string: url)!) }
        sleep(8)
        shot("00-hero-loaded")
        sleep(4)
        shot("01-hero-after-12s")
        let page = safari.webViews.firstMatch.exists ? safari.webViews.firstMatch : safari
        for i in 1...14 {
            page.swipeUp(velocity: i % 3 == 0 ? .fast : .default)
            sleep(3)
            shot(String(format: "down-%02d", i))
        }
        for i in 1...6 {
            page.swipeDown(velocity: .fast)
            sleep(2)
            shot(String(format: "up-%02d", i))
        }
        let replay = safari.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'replay'")).firstMatch
        if replay.waitForExistence(timeout: 3) {
            replay.tap()
            sleep(2); shot("replay-2s")
            sleep(4); shot("replay-6s")
        } else {
            shot("replay-not-found")
        }
    }
}
