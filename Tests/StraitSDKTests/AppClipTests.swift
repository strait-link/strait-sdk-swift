@testable import StraitSDK
import XCTest

/// App Clip -> full app handoff through a shared App Group (beta).
final class AppClipTests: XCTestCase {
    private let link = URL(string: "https://hilltop.strait.link/sale?utm_source=qr")!

    func testSaveThenTakeOnce() {
        let store = MemoryStorage()
        XCTAssertTrue(StraitAppClip.saveInvocation(link, storage: store, now: 1_000))
        XCTAssertEqual(StraitAppClip.takeInvocation(storage: store, now: 2_000), link)
        XCTAssertNil(StraitAppClip.takeInvocation(storage: store, now: 3_000), "taken once, never twice")
    }

    func testStaleInvocationIsClearedAndIgnored() {
        let store = MemoryStorage()
        StraitAppClip.saveInvocation(link, storage: store, now: 0)
        XCTAssertNil(StraitAppClip.takeInvocation(storage: store, now: StraitAppClip.maxAgeMs + 1))
        XCTAssertEqual(store.getItem(StraitAppClip.invocationKey), "")
    }

    func testOnlyHttpsLinksAreKept() {
        let store = MemoryStorage()
        XCTAssertFalse(StraitAppClip.saveInvocation(URL(string: "myapp://sale")!, storage: store, now: 0))
        XCTAssertFalse(StraitAppClip.saveInvocation(URL(string: "http://hilltop.strait.link/sale")!, storage: store, now: 0))
        XCTAssertNil(StraitAppClip.takeInvocation(storage: store, now: 1))
    }

    func testGarbageAndFutureRecordsAreIgnored() {
        let store = MemoryStorage()
        store.setItem(StraitAppClip.invocationKey, "{not json")
        XCTAssertNil(StraitAppClip.takeInvocation(storage: store, now: 1))
        store.setItem(StraitAppClip.invocationKey, #"{"url":"https://a.strait.link/x","at":999999999}"#)
        XCTAssertNil(StraitAppClip.takeInvocation(storage: store, now: 1), "a record from the future is not trusted")
    }

    func testLaterInvocationReplacesEarlier() {
        let store = MemoryStorage()
        StraitAppClip.saveInvocation(URL(string: "https://hilltop.strait.link/old")!, storage: store, now: 0)
        StraitAppClip.saveInvocation(link, storage: store, now: 10)
        XCTAssertEqual(StraitAppClip.takeInvocation(storage: store, now: 20), link)
    }

    func testAppGroupStorageNeedsAName() {
        XCTAssertNil(StraitAppClip.storage(appGroup: ""))
    }

    /// The full app hands the clip link to start(initialURL:): an exact direct
    /// link (resolved by the engine), and no deferred check on that launch.
    func testFullAppStartsWithTheClipLinkInsteadOfTheDeferredCheck() throws {
        let group = MemoryStorage()
        StraitAppClip.saveInvocation(URL(string: "https://links.test/sale")!, storage: group, now: 1_000_000)
        let h = Harness(FakeEngine(["/v1/resolve": ["matched": true, "longUrl": "https://shop.example/p/42", "linkId": "lnk_42"]]))
        h.start(StraitAppClip.takeInvocation(storage: group, now: 1_000_100)?.absoluteString)
        let e = try XCTUnwrap(h.events.first)
        XCTAssertEqual(e.kind, .direct)
        XCTAssertEqual(e.route, .appLink)
        XCTAssertEqual(e.path, "/p/42")
        XCTAssertTrue(h.engine.calls(to: "/v1/match").isEmpty, "the exact clip link replaces the deferred check")
    }
}

/// The live dashboard choice as last reported by the engine (for settings screens).
final class InstallSettingsTests: XCTestCase {
    func testLastInstallSettingsFollowsTheMatchReply() {
        let h = Harness(FakeEngine(["/v1/match": ["matched": false, "ios": ["deviceMatching": false, "pasteHandoff": true]]]))
        XCTAssertNil(h.strait.lastInstallSettings, "nothing before the engine answers")
        h.start()
        XCTAssertEqual(h.strait.lastInstallSettings?.deviceMatching, false)
        XCTAssertEqual(h.strait.lastInstallSettings?.pasteHandoff, true)
        XCTAssertEqual(h.strait.lastInstallSettings?.summary, "Paste handoff only")
    }

    func testNoIosObjectMeansUnknown() {
        XCTAssertNil(replyInstallSettings(["matched": false], at: 0))
        let s = replyInstallSettings(["ios": ["deviceMatching": "yes"]], at: 5)
        XCTAssertEqual(s, InstallSettings(deviceMatching: false, pasteHandoff: false, at: 5))
        XCTAssertEqual(s?.summary, "Neither (no deferred link on iPhone)")
    }

    func testOfflineKeepsThePreviousAnswer() {
        let engine = FakeEngine(["/v1/match": ["matched": false, "ios": ["deviceMatching": true, "pasteHandoff": false]]])
        let h = Harness(engine)
        h.start()
        XCTAssertEqual(h.strait.lastInstallSettings?.summary, "Device matching only")
        engine.offline = true
        h.strait.checkDeferred()
        XCTAssertEqual(h.strait.lastInstallSettings?.summary, "Device matching only")
    }
}
