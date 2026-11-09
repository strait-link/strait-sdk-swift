import XCTest
@testable import StraitSDK

/// Contract B27 (shared-spec ADR 0009, engine ADR 0110), port of sdk-react-native/test/user-id.test.ts:
/// `setUserId(_:)` after the app's own sign-in; later events carry it on the app.event webhook. Emails and
/// phone numbers are hashed on the device. The `userId` vector group runs in ConformanceTests.

final class Sha256HexTests: XCTestCase {
    func testKnownDigests() {
        XCTAssertEqual(sha256Hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

final class UserIdFieldTests: XCTestCase {
    func testKeepsAnOpaqueIdTrimmed() {
        XCTAssertEqual(userIdField("  user_4821 "), UserIdField(userId: "user_4821", userIdHashed: false))
    }

    func testHashesAnEmailLowerCasedAndTrimmed() {
        XCTAssertEqual(userIdField(" Priya@Example.COM "), UserIdField(userId: sha256Hex("priya@example.com"), userIdHashed: true))
    }

    func testHashesAPhoneNumberAsItsDigits() {
        XCTAssertEqual(userIdField("+91 98765-43210"), UserIdField(userId: sha256Hex("919876543210"), userIdHashed: true))
    }

    func testDropsEmptyTooLongAndControlCharacters() {
        for bad in [nil, "", "   ", String(repeating: "x", count: USER_ID_MAX + 1), "a\nb", "a\r\nb"] {
            XCTAssertNil(userIdField(bad), String(describing: bad))
        }
        let max = String(repeating: "x", count: USER_ID_MAX)
        XCTAssertEqual(userIdField(max), UserIdField(userId: max, userIdHashed: false))
    }
}

private let routes: [String: [String: Any]] = ["/v1/event": ["ok": true], "/v1/open": ["ok": true]]

final class SetUserIdTests: XCTestCase {
    private func make(_ storage: MemoryStorage = MemoryStorage()) -> Harness {
        storage.setItem("strait.deferredChecked", "1")
        let h = Harness(FakeEngine(routes), storage: storage)
        h.start()
        return h
    }

    private func events(_ h: Harness) -> [[String: Any]] { h.engine.calls(to: "/v1/event").compactMap(\.body) }

    private func queue(_ h: Harness) throws -> [[String: Any]] {
        guard let raw = h.storage.getItem("strait.pendingOpens") else { return [] }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]])
    }

    func testEventsAfterSetUserIdCarryItAndNilStopsIt() {
        let h = make()
        h.strait.trackEvent("open_cart")
        h.strait.setUserId("user_4821")
        h.strait.trackEvent("purchase")
        h.strait.setUserId(nil)
        h.strait.trackEvent("after_logout")
        let e = events(h)
        XCTAssertEqual(e.count, 3)
        XCTAssertNil(e[0]["userId"])
        XCTAssertEqual(e[1]["event"] as? String, "purchase")
        XCTAssertEqual(e[1]["userId"] as? String, "user_4821")
        XCTAssertEqual(e[1]["userIdHashed"] as? Bool, false)
        XCTAssertNil(e[2]["userId"])
        XCTAssertNil(e[2]["userIdHashed"])
    }

    func testOnlyEventsCarryIt() {
        let h = make()
        h.strait.setUserId("user_4821")
        h.strait.handle(urlString: "acme://product/42")
        h.strait.trackEvent("purchase")
        for c in h.engine.calls where c.path != "/v1/event" {
            XCTAssertNil(c.body?["userId"], c.path)
            XCTAssertNil(c.body?["userIdHashed"], c.path)
        }
        XCTAssertEqual(events(h).first?["userId"] as? String, "user_4821")
    }

    func testAnEmailNeverLeavesTheDeviceOnlyItsHashIsSentAndQueued() throws {
        let h = make()
        h.engine.modes["/v1/event"] = .offline
        h.strait.setUserId("Priya@Example.com")
        h.strait.trackEvent("purchase")
        let hash = sha256Hex("priya@example.com")
        let sent = try XCTUnwrap(events(h).first)
        XCTAssertEqual(sent["userId"] as? String, hash)
        XCTAssertEqual(sent["userIdHashed"] as? Bool, true)
        let raw = try XCTUnwrap(h.storage.getItem("strait.pendingOpens"))
        XCTAssertTrue(raw.contains(hash))
        XCTAssertNil(raw.range(of: "priya", options: .caseInsensitive))
        // Sent later from the queue: still only the hash.
        h.engine.modes["/v1/event"] = nil
        h.strait.flushOpenReports()
        let retried = try XCTUnwrap(events(h).last)
        XCTAssertEqual(retried["userId"] as? String, hash)
        XCTAssertEqual(retried["userIdHashed"] as? Bool, true)
    }

    func testTheIdAtTrackTimeIsTheOneSentEvenWhenSentLater() throws {
        let h = make()
        h.engine.modes["/v1/event"] = .offline
        h.strait.setUserId("user_1")
        h.strait.trackEvent("purchase")
        h.strait.setUserId("user_2")
        XCTAssertEqual(try queue(h).first?["userId"] as? String, "user_1")
        h.engine.modes["/v1/event"] = nil
        h.strait.flushOpenReports()
        XCTAssertEqual(events(h).last?["userId"] as? String, "user_1")
    }

    func testOptOutClearsItAndSetUserIdWhileOffIsIgnored() {
        let h = make()
        h.strait.setUserId("user_4821")
        h.strait.setEnabled(false)
        h.strait.setUserId("user_9")
        h.strait.setEnabled(true)
        h.strait.trackEvent("purchase")
        let e = events(h)
        XCTAssertEqual(e.count, 1)
        XCTAssertNil(e.first?["userId"])
    }

    func testAStoredOptOutWinsBeforeStart() {
        let s = MemoryStorage()
        s.setItem("strait.enabled", "0")
        s.setItem("strait.deferredChecked", "1")
        let h = Harness(FakeEngine(routes), storage: s)
        h.strait.setUserId("user_4821")
        h.start()
        h.strait.setEnabled(true)
        h.strait.trackEvent("purchase")
        XCTAssertEqual(events(h).count, 1)
        XCTAssertNil(events(h).first?["userId"])
    }

    func testABadValueClearsThePreviousId() {
        let h = make()
        h.strait.setUserId("user_1")
        h.strait.setUserId(String(repeating: "x", count: USER_ID_MAX + 1))
        h.strait.trackEvent("purchase")
        XCTAssertNil(events(h).first?["userId"])
    }
}
