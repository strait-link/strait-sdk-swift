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
        h.strait.handle(urlString: "https://links.test/sale") // a short link needs a lookup, which counts the tap
        XCTAssertEqual(track(h, "purchase", eventId: "ord_1"), false)
        h.strait.flushOpenReports()
        var checked: LinkEvent?
        h.strait.checkDeferred { checked = $0 }
        XCTAssertEqual(checked?.reason, "disabled")
        XCTAssertEqual(h.engine.calls.map(\.path), [])
        XCTAssertTrue(h.events.contains { $0.matched && $0.rawUrl == "acme://product/42" })
        XCTAssertTrue(h.events.contains { !$0.matched && $0.reason == "disabled" && $0.rawUrl == "https://links.test/sale" })
        var pending = -1
        h.strait.pendingOpenReports { pending = $0 }
        XCTAssertEqual(pending, 0, "reports saved before the opt-out are deleted")
        XCTAssertEqual(s.getItem("strait.deferredChecked") ?? "", "", "the check is still due")
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
