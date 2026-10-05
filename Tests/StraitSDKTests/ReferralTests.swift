import XCTest
@testable import StraitSDK

/// Contract B21 (proposal): a matched deferred reply's `referralCode` reaches
/// the app on the LinkEvent, unchanged, only when it is a valid code.
private let handoff = "https://links.test/h/AbCdEfGhIjKlMnOpQrStUv"
private let matchedReply: [String: Any] = [
    "matched": true, "longUrl": "https://shop.example/invite", "linkId": "lnk_42",
    "clickId": "3f2a9c1e-7b4d-4e8a-9c0f-1a2b3c4d5e6f",
]
private func with(_ extra: [String: Any]) -> [String: Any] { matchedReply.merging(extra) { $1 } }

final class ReferralTests: XCTestCase {
    func testReplyReferralCodeKeepsValidCodesExactly() {
        for c in ["ASHA42", "a", "user_12-b", String(repeating: "x", count: 64)] { XCTAssertEqual(replyReferralCode(c), c) }
        let bad: [Any?] = [nil, "", String(repeating: "x", count: 65), "a b", "me@example.com", "+919999", "ü", 42, NSNull(), ["A"]]
        for c in bad { XCTAssertNil(replyReferralCode(c), "\(String(describing: c))") }
    }

    func testSignalMatchCarriesTheCode() throws {
        let h = Harness(FakeEngine(["/v1/match": with(["matchMethod": "exact_ext", "referralCode": "RAVI7"])]))
        h.start()
        let e = try XCTUnwrap(h.events.last)
        XCTAssertEqual(e.route, .fingerprint)
        XCTAssertEqual(e.referralCode, "RAVI7")
    }

    func testClipboardClaimAndPasteButtonCarryTheCode() throws {
        let claim = with(["matchMethod": "clipboard", "referralCode": "ASHA42"])
        let h = Harness(FakeEngine(["/v1/match": ["matched": false], "/v1/handoff/claim": claim]),
                        clipboardBoost: true, pasteboard: SpyPasteboard(probableURL: true, text: handoff))
        h.start()
        XCTAssertEqual(h.events.last?.route, .clipboard)
        XCTAssertEqual(h.events.last?.referralCode, "ASHA42")
        var got: LinkEvent?
        h.strait.claimHandoff(text: handoff) { got = $0 }
        XCTAssertEqual(got?.referralCode, "ASHA42")
    }

    func testNoCodeInvalidCodeOrNoMatchGivesNil() throws {
        let replies: [[String: Any]] = [
            matchedReply, with(["referralCode": "not valid"]), with(["referralCode": NSNull()]),
            ["matched": false, "referralCode": "ASHA42"],
        ]
        for reply in replies {
            let h = Harness(FakeEngine(["/v1/match": reply]))
            h.start()
            XCTAssertNil(try XCTUnwrap(h.events.last).referralCode, "\(reply)")
        }
    }

    func testLegacyMatchResultDecodesTheCode() throws {
        let data = Data(#"{"matched":true,"longUrl":"https://x","linkId":"l","matchMethod":"install_referrer","referralCode":"ASHA42"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(MatchResult.self, from: data).referralCode, "ASHA42")
        let old = Data(#"{"matched":false,"matchMethod":"none"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(MatchResult.self, from: old).referralCode)
    }
}
