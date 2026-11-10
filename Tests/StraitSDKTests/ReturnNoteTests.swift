import XCTest
@testable import StraitSDK

/// B28 (shared-spec ADR 0012), port of sdk-react-native/test/return-note.test.ts: at most three
/// "came back" notes per install (day 1, 7, 30), carrying the install's tap id.

private let CLICK = "3f2a9c1e-7b4d-4e8a-9c0f-1a2b3c4d5e6f"
private let OTHER = "11111111-2222-4333-8444-555555555555"
private let T: Double = 1_800_000_000_000

private func tap(_ s: MemoryStorage) throws -> [String: Any] {
    let raw = try XCTUnwrap(s.getItem("strait.installTap"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
}

private func notes(_ e: FakeEngine) -> [FakeEngine.Call] { e.calls.filter { $0.body?["kind"] as? String == "return" } }

final class ReturnNotePureTests: XCTestCase {
    func testDueExactlyOnDay1And7And30OnceEach() {
        let s = installTapValue(CLICK, at: T)
        XCTAssertNil(returnNote(s, now: T + DAY_MS - 1))
        XCTAssertEqual(returnNote(s, now: T + DAY_MS), ReturnNote(day: 1, clickId: CLICK, openId: "r1-\(CLICK)"))
        XCTAssertNil(returnNote(s, now: T + 2 * DAY_MS))
        XCTAssertEqual(returnNote(s, now: T + 7 * DAY_MS + 5)?.day, 7)
        XCTAssertEqual(returnNote(s, now: T + 30 * DAY_MS)?.day, 30)
        XCTAssertNil(returnNote(s, now: T + 31 * DAY_MS))
        XCTAssertNil(returnNote(installTapValue(CLICK, at: T, sent: [1]), now: T + DAY_MS))
    }

    func testABoolInSentIsNotADay() {
        XCTAssertEqual(returnNote(#"{"clickId":"\#(CLICK)","at":1800000000000,"sent":[true]}"#, now: T + DAY_MS)?.day, 1)
        XCTAssertNil(returnNote(#"{"clickId":"\#(CLICK)","at":true,"sent":[]}"#, now: T + DAY_MS))
        XCTAssertNil(returnNote(#"{"clickId":"\#(CLICK)","at":1e-300,"sent":[]}"#, now: 1e300), "huge day count is no crash")
    }
}

final class ReturnNoteClientTests: XCTestCase {
    private let match: [String: [String: Any]] = [
        "/v1/match": ["matched": true, "clickId": CLICK.uppercased(), "longUrl": "https://shop.example/p/1"],
        "/v1/open": ["ok": true],
    ]

    func testInstallMatchKeepsTheTapDay1SendsOneNoteASecondForegroundSendsNothing() throws {
        let s = MemoryStorage()
        let e = FakeEngine(match)
        let h = Harness(e, storage: s, installTime: { T }, appVersion: "2.1.0")
        h.clock.t = T
        h.start()
        let stored = try tap(s)
        XCTAssertEqual(stored["clickId"] as? String, CLICK)
        XCTAssertEqual(stored["at"] as? Double, T)
        XCTAssertEqual(stored["sent"] as? [Int], [])
        XCTAssertTrue(notes(e).isEmpty, "day 0: nothing")

        let h2 = Harness(e, storage: s, installTime: { T }, appVersion: "2.1.0")
        h2.clock.t = T + DAY_MS + 60_000
        h2.start()
        h2.strait.onAppState(.active)
        let sent = notes(e)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.path, "/v1/open")
        let body = try XCTUnwrap(sent.first?.body)
        XCTAssertEqual(Set(body.keys), ["publishableKey", "openId", "kind", "day", "clickId", "platform", "at", "appVersion", "sdkVersion"])
        XCTAssertEqual(body["openId"] as? String, "r1-\(CLICK)")
        XCTAssertEqual(body["day"] as? Int, 1)
        XCTAssertEqual(body["clickId"] as? String, CLICK)
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["at"] as? Double, T + DAY_MS + 60_000)
        XCTAssertEqual(body["appVersion"] as? String, "2.1.0")
        XCTAssertEqual(body["sdkVersion"] as? String, StraitLinks.wireSdkVersion)
        XCTAssertEqual(try tap(s)["sent"] as? [Int], [1])
    }

    func testALaterTapNeverReplacesTheInstallTapAndARestoredBackupIsCleared() throws {
        let s = MemoryStorage()
        s.setItem("strait.installTap", installTapValue(OTHER, at: T - 40 * DAY_MS)) // a backup of another install
        let h = Harness(FakeEngine(match), storage: s, installTime: { T })
        h.clock.t = T
        h.start()
        h.strait.handle(urlString: "acme://p/2?strait_click=\(OTHER)")
        XCTAssertEqual(try tap(s)["clickId"] as? String, CLICK)
        XCTAssertTrue(s.getItem("strait.lastTap")?.contains(OTHER) == true)
    }

    func testAFirstLaunchOpenedByALinkWithATapIdKeepsThatTap() throws {
        let s = MemoryStorage()
        let h = Harness(FakeEngine(["/v1/open": ["ok": true]]), storage: s, installTime: { T })
        h.clock.t = T
        h.start("acme://p/2?strait_click=\(CLICK)")
        XCTAssertEqual(try tap(s)["clickId"] as? String, CLICK)
        XCTAssertEqual(try tap(s)["at"] as? Double, T)
    }

    func testAnUnreadableWriteSendsNothing() {
        final class DropTap: StraitStorage {
            let inner = MemoryStorage()
            func getItem(_ key: String) -> String? { inner.getItem(key) }
            func setItem(_ key: String, _ value: String) { if key != "strait.installTap" { inner.setItem(key, value) } }
        }
        let s = DropTap()
        s.inner.setItem("strait.deferredChecked", "1")
        s.inner.setItem("strait.installTap", installTapValue(CLICK, at: T))
        let e = FakeEngine(["/v1/open": ["ok": true]])
        let links = StraitLinks(StraitLinksConfig(
            publishableKey: "st_pub_test_x", endpoint: "https://links.test", storage: s, transport: e,
            now: { T + DAY_MS }, callbackQueue: nil, observeLifecycle: false, installTime: { nil }
        ))
        links.start()
        links.onAppState(.active)
        XCTAssertTrue(notes(e).isEmpty, "the day could not be marked: no note (never one on every foreground)")
    }

    func testOfflineQueuesThenFlushesOptedOutSendsNothingAndDeletesTheInstallTap() throws {
        let s = MemoryStorage()
        s.setItem("strait.deferredChecked", "1")
        s.setItem("strait.installTap", #"{"clickId":"\#(CLICK)","at":1800000000000,"sent":[1]}"#)
        let e = FakeEngine(["/v1/open": ["ok": true]])
        e.modes["/v1/open"] = .status(503)
        let h = Harness(e, storage: s)
        h.clock.t = T + 7 * DAY_MS
        h.start()
        let raw = try XCTUnwrap(s.getItem("strait.pendingOpens"))
        let queued = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]])
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?["type"] as? String, "return")
        XCTAssertEqual(queued.first?["openId"] as? String, "r7-\(CLICK)")
        XCTAssertEqual(queued.first?["day"] as? Int, 7)
        XCTAssertNil(queued.first?["publishableKey"])

        e.modes["/v1/open"] = nil
        h.clock.advance(3_600_000) // past the C1 hold
        h.strait.flushOpenReports()
        let last = try XCTUnwrap(e.calls.last?.body)
        XCTAssertEqual(last["openId"] as? String, "r7-\(CLICK)")
        XCTAssertEqual(last["kind"] as? String, "return")
        XCTAssertEqual(last["publishableKey"] as? String, "bk_pub_test_appowner01")
        XCTAssertNil(last["type"])
        XCTAssertNil(last["deviceClass"])
        var pending = -1
        h.strait.pendingOpenReports { pending = $0 }
        XCTAssertEqual(pending, 0)

        h.strait.setEnabled(false)
        XCTAssertEqual(s.getItem("strait.installTap"), "")
        h.clock.t = T + 30 * DAY_MS
        let before = e.calls.count
        h.strait.onAppState(.active)
        XCTAssertEqual(e.calls.count, before)
    }

    func testOptedOutComputesAndWritesNothing() throws {
        let s = MemoryStorage()
        s.setItem("strait.deferredChecked", "1")
        let stored = installTapValue(CLICK, at: T)
        s.setItem("strait.installTap", stored)
        s.setItem("strait.enabled", "0")
        let e = FakeEngine(["/v1/open": ["ok": true]])
        let h = Harness(e, storage: s)
        h.clock.t = T + DAY_MS
        h.start()
        h.strait.onAppState(.active)
        XCTAssertTrue(e.calls.isEmpty)
        XCTAssertEqual(s.getItem("strait.installTap"), stored)
    }
}
