import XCTest
@testable import StraitSDK

/// Contract B13a (shared-spec ADR 0004), port of sdk-react-native/test/events-v2.test.ts:
/// trackEvent sends an eventId (the app's order id, else one the SDK makes) and keeps events
/// that don't get through in the open-report queue.

private let EVENT_ID = "^e_[a-z0-9]+_[a-z0-9]{12}$"
private let ENGINE_RULE = "^[A-Za-z0-9_.:-]{1,64}$"
private let PK = "bk_pub_test_appowner01"
private let TAP = "3f2a9c1e-7b4d-4e8a-9c0f-1a2b3c4d5e6f"

private func matches(_ s: String?, _ pattern: String) -> Bool {
    s?.range(of: pattern, options: .regularExpression) != nil
}

final class NewEventIdTests: XCTestCase {
    func testHasTheEngineEventIdShapeAndIsUnique() {
        let a = newEventId(1_800_000_000_000)
        XCTAssertTrue(matches(a, EVENT_ID), a)
        XCTAssertTrue(matches(a, ENGINE_RULE), a)
        XCTAssertTrue(a.hasPrefix("e_\(String(1_800_000_000_000, radix: 36))_"), a)
        XCTAssertEqual(newEventId(36, random: { 0 }), "e_10_aaaaaaaaaaaa")
        XCTAssertNotEqual(newEventId(1), newEventId(1))
    }
}

final class TrackEventV2Tests: XCTestCase {
    private func make() -> Harness {
        let s = MemoryStorage()
        s.setItem("strait.deferredChecked", "1")
        let h = Harness(FakeEngine(["/v1/event": ["ok": true], "/v1/open": ["ok": true]]), storage: s)
        h.start()
        return h
    }

    private func track(_ h: Harness, _ name: String, value: Double? = nil, currency: String? = nil, eventId: String? = nil) -> Bool? {
        var ok: Bool?
        h.strait.trackEvent(name, value: value, currency: currency, eventId: eventId) { ok = $0 }
        return ok
    }

    private func queue(_ h: Harness) throws -> [[String: Any]] {
        guard let raw = h.storage.getItem("strait.pendingOpens") else { return [] }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]])
    }

    private func events(_ h: Harness) -> [[String: Any]] { h.engine.calls(to: "/v1/event").compactMap(\.body) }

    private func pending(_ h: Harness) -> Int {
        var n = -1
        h.strait.pendingOpenReports { n = $0 }
        return n
    }

    func testSendsTheAppsEventIdAsIs() throws {
        let h = make()
        XCTAssertEqual(track(h, "purchase", value: 499, currency: "INR", eventId: "ord_1001"), true)
        let body = try XCTUnwrap(events(h).first)
        XCTAssertEqual(body["publishableKey"] as? String, PK)
        XCTAssertEqual(body["event"] as? String, "purchase")
        XCTAssertEqual(body["value"] as? Double, 499)
        XCTAssertEqual(body["currency"] as? String, "INR")
        XCTAssertEqual(body["eventId"] as? String, "ord_1001")
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertNil(body["type"])
        XCTAssertNil(body["at"])
    }

    func testMakesAnEventIdWhenTheAppGivesNone() {
        let h = make()
        _ = track(h, "signup")
        let id = events(h).first?["eventId"] as? String
        XCTAssertTrue(matches(id, EVENT_ID), String(describing: id))
    }

    func testOfflineReturnsFalseKeepsTheEventWithoutTheKeyAndSendsItLaterWithTheSameEventId() throws {
        let h = make()
        h.engine.modes["/v1/event"] = .offline
        XCTAssertEqual(track(h, "purchase", value: 5, currency: "USD", eventId: "ord_7"), false)
        let saved = try queue(h)
        XCTAssertEqual(saved as NSArray, [[
            "type": "event", "at": 1_000_000, "event": "purchase", "platform": "ios", "value": 5, "currency": "USD", "eventId": "ord_7",
        ]] as NSArray)
        XCTAssertFalse(try XCTUnwrap(h.storage.getItem("strait.pendingOpens")).contains("bk_pub_"))
        XCTAssertEqual(pending(h), 1)
        h.engine.modes["/v1/event"] = nil
        h.strait.onAppState(.active)
        XCTAssertEqual(events(h).last as NSDictionary?, [
            "publishableKey": PK, "event": "purchase", "platform": "ios", "value": 5, "currency": "USD", "eventId": "ord_7",
        ] as NSDictionary)
        XCTAssertTrue(h.engine.calls(to: "/v1/open").isEmpty, "never sent as an open report")
        XCTAssertEqual(try queue(h).count, 0)
    }

    func testKeeps5xxAnd429ButNotAnother4xx() throws {
        let h = make()
        h.engine.modes["/v1/event"] = .status(400)
        XCTAssertEqual(track(h, "c", eventId: "bad id!"), false)
        h.engine.modes["/v1/event"] = .status(503)
        _ = track(h, "a")
        h.engine.modes["/v1/event"] = .status(429)
        _ = track(h, "b")
        XCTAssertEqual(try queue(h).map { $0["event"] as? String }, ["a", "b"])
        XCTAssertEqual(pending(h), 2)
    }

    func testOpensAndEventsShareTheQueueInOrderAndARetryIsSentOnce() throws {
        let h = make()
        h.engine.modes["/v1/event"] = .offline
        _ = track(h, "purchase", eventId: "ord_9")
        // An open report saved earlier by the B14 path sits in the same queue.
        let open: [String: Any] = [
            "openId": "o_1_aaaaaaaaaaaa", "kind": "direct", "route": "app_link", "appState": "closed",
            "platform": "ios", "matched": true, "firstLaunch": false, "at": 1_000_000,
        ]
        let combined = try JSONSerialization.data(withJSONObject: [open] + (try queue(h)))
        h.storage.setItem("strait.pendingOpens", String(decoding: combined, as: UTF8.self))
        XCTAssertEqual(pending(h), 2)
        h.engine.modes["/v1/event"] = nil
        var flushed = false
        h.strait.flushOpenReports { flushed = true }
        XCTAssertTrue(flushed)
        XCTAssertEqual(h.engine.calls(to: "/v1/open").map { $0.body?["openId"] as? String }, ["o_1_aaaaaaaaaaaa"])
        XCTAssertEqual(events(h).filter { $0["eventId"] as? String == "ord_9" }.count, 2, "the failed try + one retry")
        XCTAssertEqual(try queue(h).count, 0)
        h.strait.flushOpenReports()
        XCTAssertEqual(events(h).count, 2, "dropped once the engine took it")
    }

    func testAnUnansweredEventStopsTheFlushAndKeepsTheRest() throws {
        let h = make()
        h.engine.modes["/v1/event"] = .offline
        h.engine.modes["/v1/open"] = .offline
        _ = track(h, "first", eventId: "ord_1")
        h.strait.handle(urlString: "straitlink://a.b/1")
        XCTAssertEqual(pending(h), 2)
        let opensBefore = h.engine.calls(to: "/v1/open").count
        h.engine.modes["/v1/open"] = nil
        h.strait.flushOpenReports()
        XCTAssertEqual(h.engine.calls(to: "/v1/open").count, opensBefore, "stopped at the unanswered event")
        XCTAssertEqual(pending(h), 2)
    }

    func testAnAnsweredEventAlsoSendsEarlierSavedReports() {
        let h = make()
        h.engine.modes["/v1/open"] = .offline
        h.strait.handle(urlString: "straitlink://a.b/old")
        XCTAssertEqual(pending(h), 1)
        h.engine.modes["/v1/open"] = nil
        XCTAssertEqual(track(h, "purchase"), true)
        XCTAssertEqual(pending(h), 0)
    }

    func testTheTapIdIsChosenWhenTheAppCallsNotAtRetryTime() throws {
        let h = make()
        h.storage.setItem(StraitLinks.tapKey, rememberTap(TAP, at: h.clock.t))
        h.engine.modes["/v1/event"] = .offline
        _ = track(h, "purchase", eventId: "ord_10")
        h.storage.setItem(StraitLinks.tapKey, "")
        XCTAssertEqual(try queue(h).first?["clickId"] as? String, TAP)
        h.engine.modes["/v1/event"] = nil
        h.strait.flushOpenReports()
        XCTAssertEqual(events(h).last?["clickId"] as? String, TAP)
    }
}
