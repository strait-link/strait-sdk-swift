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

    /// F4: the switch goes off while /v1/resolve is out and that call fails: route via /v1/lookup, not
    /// "network", and queue nothing.
    func testSwitchedOffWhileResolveIsOutAndFailsRoutesThroughLookup() {
        var routes = engineRoutes
        routes["/v1/lookup"] = ["matched": true, "longUrl": "https://shop.example/p/42", "linkId": "lnk_42"]
        let engine = FakeEngine(routes)
        engine.modes["/v1/resolve"] = .offline
        let s = MemoryStorage()
        let h = Harness(engine, storage: s)
        h.start()
        engine.onCall["/v1/resolve"] = { h.strait.setEnabled(false) }
        engine.calls = []
        h.strait.handle(urlString: "https://links.test/sale")
        XCTAssertEqual(engine.calls.map(\.path), ["/v1/resolve", "/v1/lookup"])
        let e = h.events.last
        XCTAssertEqual(e?.matched, true)
        XCTAssertNil(e?.reason)
        XCTAssertEqual(e?.path, "/p/42")
        var pending = -1
        h.strait.pendingOpenReports { pending = $0 }
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(s.getItem("strait.lastTap") ?? "", "")
    }

    /// The reply lands after the switch went off: the link routes, but no tap is kept and nothing is queued.
    func testSwitchedOffWhileResolveIsOutAndAnswersKeepsNoTap() {
        var routes = engineRoutes
        routes["/v1/resolve"] = ["matched": true, "longUrl": "https://shop.example/p/42", "linkId": "lnk_42",
                                 "clickId": "3f2a9c1e-7b4d-4e8a-9f10-2c3d4e5f6a7b"]
        let engine = FakeEngine(routes)
        let s = MemoryStorage()
        let h = Harness(engine, storage: s)
        h.start()
        engine.onCall["/v1/resolve"] = { h.strait.setEnabled(false) }
        engine.calls = []
        h.strait.handle(urlString: "https://links.test/sale")
        XCTAssertEqual(h.events.last?.matched, true)
        XCTAssertEqual(engine.calls.map(\.path), ["/v1/resolve"])
        var pending = -1
        h.strait.pendingOpenReports { pending = $0 }
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(s.getItem("strait.lastTap") ?? "", "")
    }

    /// F7: switched off during the first-launch check: no clipboard read (iOS shows a paste prompt).
    private let pasteOnMiss: [String: Any] = ["matched": false, "matchMethod": "none", "ios": ["deviceMatching": true, "pasteHandoff": true]]

    func testSwitchedOffWhileMatchIsOutLeavesTheClipboardAlone() {
        let engine = FakeEngine(["/v1/match": pasteOnMiss])
        let clip = SpyPasteboard(text: "https://links.test/h/AbCdEfGhIjKlMnOpQrStUv")
        let h = Harness(engine, storage: MemoryStorage(), pasteboard: clip)
        engine.onCall["/v1/match"] = { h.strait.setEnabled(false) }
        h.start()
        XCTAssertEqual(clip.touched, 0, "no paste prompt for an opted-out person")
        XCTAssertEqual(engine.calls.map(\.path), ["/v1/match"])
    }

    func testSwitchedOffBetweenTheDetectAndTheReadDoesNotRead() {
        let engine = FakeEngine(["/v1/match": pasteOnMiss])
        let clip = SpyPasteboard(text: "https://links.test/h/AbCdEfGhIjKlMnOpQrStUv")
        let h = Harness(engine, storage: MemoryStorage(), pasteboard: clip)
        clip.duringDetect = { h.strait.setEnabled(false) }
        h.start()
        XCTAssertEqual(clip.detectCalls, 1)
        XCTAssertEqual(clip.readCalls, 0)
        XCTAssertEqual(engine.calls.map(\.path), ["/v1/match"])
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
