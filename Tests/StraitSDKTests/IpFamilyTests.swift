import XCTest
@testable import StraitSDK

/// B24 (engine ADR 0101): the first-launch check asked over IPv6 and found nothing; the engine names its
/// IPv4-only URL and the SDK asks once more there, same openId, same fields. Only a match there counts.
private let V4 = "https://v4.straitlink.test/v1/match"
private let missV6: [String: Any] = ["matched": false, "matchMethod": "none", "reasons": ["no_candidate"],
                                     "ios": ["deviceMatching": true, "pasteHandoff": false], "ipv4Match": V4]
private let hitV4: [String: Any] = ["matched": true, "longUrl": "https://shop.example/promo/42", "linkId": "lnk_42",
                                    "clickId": "11111111-2222-4333-8444-555555555555", "matchMethod": "exact_ext",
                                    "reasons": ["exact_ext", "ip_family"], "match": ["method": "fingerprint", "confidence": "probable"]]

final class IpFamilyTests: XCTestCase {
    func testAsksTheIpv4UrlOnceWithTheSameBodyAndUsesItsMatch() throws {
        let h = Harness(FakeEngine(["/v1/match": missV6, "v4.straitlink.test/v1/match": hitV4]))
        h.start()
        let calls = h.engine.calls(to: "/v1/match")
        XCTAssertEqual(calls.map(\.host), ["links.test", "v4.straitlink.test"])
        let (a, b) = (try XCTUnwrap(calls[0].body), try XCTUnwrap(calls[1].body))
        XCTAssertEqual(NSDictionary(dictionary: a), NSDictionary(dictionary: b), "same openId, same fields, nothing added")
        XCTAssertNotNil(a["openId"])
        let e = try XCTUnwrap(h.events.first)
        XCTAssertTrue(e.matched)
        XCTAssertEqual(e.url, "https://shop.example/promo/42")
        XCTAssertEqual(e.linkId, "lnk_42")
        XCTAssertEqual(e.match?.confidence, "probable")
    }

    func testNoMatchThereKeepsTheFirstAnswer() throws {
        let h = Harness(FakeEngine(["/v1/match": missV6, "v4.straitlink.test/v1/match": ["matched": false, "matchMethod": "none"]]))
        h.start()
        XCTAssertEqual(h.engine.calls(to: "/v1/match").count, 2)
        let e = try XCTUnwrap(h.events.first)
        XCTAssertFalse(e.matched)
        XCTAssertEqual(e.reason, "no_match")
    }

    func testIpv4UrlDownKeepsTheFirstAnswer() throws {
        let engine = FakeEngine(["/v1/match": missV6, "v4.straitlink.test/v1/match": hitV4])
        engine.modes["v4.straitlink.test/v1/match"] = .offline
        let h = Harness(engine)
        h.start()
        let e = try XCTUnwrap(h.events.first)
        XCTAssertFalse(e.matched)
        XCTAssertEqual(e.reason, "no_match")
    }

    func testNoSecondAskWithoutTheFieldOrWithABadUrl() {
        for bad in [nil, "http://v4.straitlink.test/v1/match", "https://v4.straitlink.test/v1/open", "https://v4.straitlink.test/v1/match?x=1", "javascript:alert(1)", "/v1/match"] as [String?] {
            var miss = missV6
            miss["ipv4Match"] = bad
            let h = Harness(FakeEngine(["/v1/match": miss, "v4.straitlink.test/v1/match": hitV4]))
            h.start()
            XCTAssertEqual(h.engine.calls(to: "/v1/match").count, 1, "\(bad ?? "nil")")
            XCTAssertFalse(h.events.first?.matched ?? true)
        }
    }

    func testNoSecondAskOnTheReadOnlyRecheck() {
        let h = Harness(FakeEngine(["/v1/match": missV6, "v4.straitlink.test/v1/match": hitV4]))
        h.start()
        let before = h.engine.calls(to: "/v1/match").count
        h.strait.checkDeferred()
        XCTAssertEqual(h.engine.calls(to: "/v1/match").count, before + 1, "record:false never asks the IPv4 URL")
    }

    func testOptedOutMidCheckSendsNothingMore() {
        let engine = FakeEngine(["/v1/match": missV6, "v4.straitlink.test/v1/match": hitV4])
        let h = Harness(engine)
        engine.onCall["/v1/match"] = { [unowned h] in if engine.calls.count == 1 { h.strait.setEnabled(false) } }
        h.start()
        XCTAssertEqual(engine.calls.filter { $0.host == "v4.straitlink.test" }.count, 0)
    }

    func testTheIpv4AskWaitsAtMostTenSeconds() {
        let h = Harness(FakeEngine(["/v1/match": missV6, "v4.straitlink.test/v1/match": hitV4]))
        h.start()
        XCTAssertEqual(h.engine.calls.first { $0.host == "v4.straitlink.test" }?.timeout, 10)
    }

    // Paste handoff (B19) reads the first answer's choice; the IPv4 ask only decides whether a match was found.
    private static let pasteMiss: [String: Any] = {
        var m = missV6
        m["ios"] = ["deviceMatching": true, "pasteHandoff": true]
        return m
    }()
    private static let handoff = "https://links.test/h/AbCdEfGhIjKlMnOpQrStUv"
    private static let claimOk: [String: Any] = ["matched": true, "longUrl": "https://shop.example/x", "linkId": "lnk_1", "matchMethod": "clipboard"]

    func testPasteHandoffStillRunsWhenTheIpv4AskMisses() throws {
        let spy = SpyPasteboard(probableURL: true, text: Self.handoff)
        let h = Harness(FakeEngine(["/v1/match": Self.pasteMiss, "v4.straitlink.test/v1/match": ["matched": false], "/v1/handoff/claim": Self.claimOk]), pasteboard: spy)
        h.start()
        XCTAssertEqual(h.engine.calls(to: "/v1/handoff/claim").count, 1)
        XCTAssertEqual(h.events.first?.route, .clipboard)
    }

    func testNoPastePromptWhenTheIpv4AskMatches() throws {
        let spy = SpyPasteboard(probableURL: true, text: Self.handoff)
        let h = Harness(FakeEngine(["/v1/match": Self.pasteMiss, "v4.straitlink.test/v1/match": hitV4, "/v1/handoff/claim": Self.claimOk]), pasteboard: spy)
        h.start()
        XCTAssertEqual(spy.touched, 0)
        XCTAssertTrue(h.engine.calls(to: "/v1/handoff/claim").isEmpty)
        XCTAssertEqual(h.events.first?.linkId, "lnk_42")
    }

    func testReplyIpv4Match() {
        XCTAssertEqual(replyIpv4Match("https://v4.straitlink.in/v1/match")?.absoluteString, "https://v4.straitlink.in/v1/match")
        for bad: Any? in [nil, 1, "", "https://v4.straitlink.in/v1/match/", "https://u:p@v4.straitlink.in/v1/match", "https:///v1/match", "ftp://x/v1/match"] {
            XCTAssertNil(replyIpv4Match(bad), "\(String(describing: bad))")
        }
    }
}
