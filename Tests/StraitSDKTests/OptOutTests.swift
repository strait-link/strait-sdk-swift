import XCTest
@testable import StraitSDK

/// Opt-out (td2-27, docs/adr/0001-opt-out.md), port of sdk-react-native/test/opt-out.test.ts: setEnabled(false) =
/// no reports, no events, no install matching, kept across launches; a link that carries its own
/// destination still reaches onLink (the app's own navigation).
final class OptOutTests: XCTestCase {
    private let engineRoutes: [String: [String: Any]] = [
        "/v1/match": ["matched": false], "/v1/event": ["ok": true], "/v1/open": ["ok": true],
    ]

    private func track(_ h: Harness, _ name: String, eventId: String? = nil) -> Bool? {
        var ok: Bool?
        h.strait.trackEvent(name, eventId: eventId) { ok = $0 }
        return ok
    }

    func testDisabledSendsNothingAndLinksStillRoute() {
        let s = MemoryStorage() // empty = a first launch (the deferred check is due)
        s.setItem("strait.pendingOpens", #"[{"openId":"o_1","kind":"direct","route":"app_link","appState":"closed","platform":"ios","matched":true,"firstLaunch":false,"at":1}]"#)
        let h = Harness(FakeEngine(engineRoutes), storage: s)
        h.strait.setEnabled(false)
        h.start()
        h.strait.handle(urlString: "acme://product/42")
        XCTAssertEqual(track(h, "purchase", eventId: "ord_1"), false)
        h.strait.flushOpenReports()
        var checked: LinkEvent?
        h.strait.checkDeferred { checked = $0 }
        XCTAssertEqual(checked?.reason, "disabled")
        XCTAssertEqual(h.engine.calls.map(\.path), [])
        XCTAssertTrue(h.events.contains { $0.matched && $0.rawUrl == "acme://product/42" })
        var pending = -1
        h.strait.pendingOpenReports { pending = $0 }
        XCTAssertEqual(pending, 0, "reports saved before the opt-out are deleted")
        XCTAssertEqual(s.getItem("strait.deferredChecked") ?? "", "", "the check is still due")
    }

    func testDisabledShortLinkStillRoutesThroughLookupWhichRecordsNothing() {
        var routes = engineRoutes
        routes["/v1/lookup"] = ["matched": true, "longUrl": "https://shop.example/p/42?color=red", "linkId": "lnk_42", "slug": "sale"]
        let s = MemoryStorage()
        let h = Harness(FakeEngine(routes), storage: s)
        h.strait.setEnabled(false)
        h.start()
        h.strait.handle(urlString: "https://links.test/sale?utm_source=sms&secret=1")
        h.strait.flushOpenReports()
        XCTAssertEqual(h.engine.calls.map(\.path), ["/v1/lookup"])
        // Only the key and host + path leave the device: no query, openId, platform, device or app state.
        let body = h.engine.calls.first?.body ?? [:]
        XCTAssertEqual(Set(body.keys), ["publishableKey", "url"])
        XCTAssertEqual(body["url"] as? String, "https://links.test/sale")
        let e = h.events.last
        XCTAssertEqual(e?.matched, true)
        XCTAssertEqual(e?.path, "/p/42")
        XCTAssertEqual(e?.params, ["color": "red"])
        var pending = -1
        h.strait.pendingOpenReports { pending = $0 }
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(s.getItem("strait.lastTap") ?? "", "", "no tap remembered")
    }

    func testDisabledLookupMissKeepsTheEngineReason() {
        var routes = engineRoutes
        routes["/v1/lookup"] = ["matched": false, "reason": "expired"]
        let h = Harness(FakeEngine(routes), storage: MemoryStorage())
        h.strait.setEnabled(false)
        h.start()
        h.strait.handle(urlString: "https://links.test/old")
        XCTAssertTrue(h.events.contains { !$0.matched && $0.reason == "expired" })
        var pending = -1
        h.strait.pendingOpenReports { pending = $0 }
        XCTAssertEqual(pending, 0)
    }

    func testDisabledLookupFailureIsDisabledAndQueuesNothing() {
        for offline in [false, true] {
            let engine = FakeEngine(engineRoutes) // no /v1/lookup route: 404, an engine without it
            engine.offline = offline
            let h = Harness(engine, storage: MemoryStorage())
            h.strait.setEnabled(false)
            h.start()
            h.strait.handle(urlString: "https://links.test/sale")
            XCTAssertTrue(h.events.contains { !$0.matched && $0.reason == "disabled" && $0.rawUrl == "https://links.test/sale" })
            var pending = -1
            h.strait.pendingOpenReports { pending = $0 }
            XCTAssertEqual(pending, 0)
        }
    }

    func testPersistsAcrossLaunches() {
        let s = MemoryStorage()
        Harness(FakeEngine(engineRoutes), storage: s).strait.setEnabled(false)
        let h = Harness(FakeEngine(engineRoutes), storage: s) // next launch, same storage
        XCTAssertFalse(h.strait.isEnabled)
        h.start()
        _ = track(h, "signup")
        XCTAssertEqual(h.engine.calls.map(\.path), [])
    }

    func testReEnableResumesAndRunsTheSkippedFirstLaunchCheck() {
        let s = MemoryStorage()
        let h = Harness(FakeEngine(engineRoutes), storage: s)
        h.strait.setEnabled(false)
        h.start()
        XCTAssertEqual(h.engine.calls.map(\.path), [])
        var done = false
        h.strait.setEnabled(true) { done = true }
        XCTAssertTrue(done)
        XCTAssertTrue(h.strait.isEnabled)
        XCTAssertTrue(h.engine.calls.map(\.path).contains("/v1/match"))
        XCTAssertEqual(s.getItem("strait.deferredChecked"), "1")
        XCTAssertEqual(track(h, "purchase", eventId: "ord_2"), true)
        XCTAssertTrue(h.engine.calls.map(\.path).contains("/v1/event"))
    }
}
