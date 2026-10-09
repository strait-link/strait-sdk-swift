import XCTest
@testable import StraitSDK

private let CLICK = "9a1c7e52-4b3d-4f8e-a6d1-0c2b5e7f9a34"
private let HANDOFF = "https://hilltop.strait.link/h/AbCdEfGhIjKlMnOpQrStUv"

final class SpyPresenter: StoreSheetPresenting {
    var shown: [(StoreProduct, StoreSheetStyle)] = []
    var answer = true
    func present(_ product: StoreProduct, style: StoreSheetStyle, completion: @escaping (Bool) -> Void) {
        shown.append((product, style))
        completion(answer)
    }
}

final class WritablePasteboard: StraitPasteboard, StraitPasteboardWriting {
    var written: [String] = []
    func hasProbableWebURL(completion: @escaping (Bool) -> Void) { completion(false) }
    func readString() -> String? { nil }
    func writeString(_ value: String) { written.append(value) }
}

private func storeSheetReply(matching: Bool = true, handoff: Any = NSNull(), campaign: Any = "autumn-sale") -> [String: Any] {
    ["ok": true, "beta": true, "clickId": CLICK, "linkId": "lnk_42",
     "ios": ["appStoreId": "6474676842", "campaignToken": campaign, "deviceMatching": matching, "handoffUrl": handoff]]
}

private func client(_ engine: FakeEngine, pasteboard: StraitPasteboard = SystemPasteboard()) -> StraitLinks {
    StraitLinks(StraitLinksConfig(
        publishableKey: "bk_pub_test_appowner01", endpoint: "https://hilltop.strait.link", storage: MemoryStorage(),
        transport: engine, now: { 1_000_000 },
        device: { DeviceFields(screenWidth: 393, pixelRatio: 3, language: "en-IN", timezone: "Asia/Kolkata") },
        callbackQueue: nil, observeLifecycle: false, pasteboard: pasteboard
    ))
}

private func open(_ s: StraitLinks, _ options: StoreSheetOptions = StoreSheetOptions(), presenter: SpyPresenter = SpyPresenter()) -> StoreSheetResult? {
    var out: StoreSheetResult?
    s.openStoreSheet(url: "https://hilltop.strait.link/promo", options: options, presenter: presenter) { out = $0 }
    return out
}

final class StoreSheetTests: XCTestCase {
    func testProductPageWithCampaignAndDeviceMatchSaved() throws {
        let engine = FakeEngine(["/v1/store-sheet": storeSheetReply(), "/v1/match-save": [:]])
        let presenter = SpyPresenter()
        let r = try XCTUnwrap(open(client(engine), presenter: presenter))
        XCTAssertTrue(r.opened)
        XCTAssertEqual(r.method, "product_page")
        XCTAssertEqual(r.clickId, CLICK)
        XCTAssertTrue(r.matchSaved)
        XCTAssertFalse(r.handoffCopied)
        XCTAssertNil(r.reason)
        XCTAssertEqual(presenter.shown.first?.0, StoreProduct(appStoreId: "6474676842", campaignToken: "autumn-sale"))
        let req = try XCTUnwrap(engine.calls(to: "/v1/store-sheet").first?.body)
        XCTAssertEqual(req["platform"] as? String, "ios")
        XCTAssertEqual(req["url"] as? String, "https://hilltop.strait.link/promo")
        let save = try XCTUnwrap(engine.calls(to: "/v1/match-save").first?.body)
        XCTAssertEqual(save["linkId"] as? String, "lnk_42")
        XCTAssertEqual(save["clickId"] as? String, CLICK)
        XCTAssertEqual(save["screenWidth"] as? Int, 393)
        XCTAssertEqual(save["timezone"] as? String, "Asia/Kolkata")
    }

    func testWorkspaceWithDeviceMatchingOffSavesNothing() throws {
        let engine = FakeEngine(["/v1/store-sheet": storeSheetReply(matching: false)])
        let r = try XCTUnwrap(open(client(engine)))
        XCTAssertTrue(r.opened)
        XCTAssertFalse(r.matchSaved)
        XCTAssertTrue(engine.calls(to: "/v1/match-save").isEmpty)
    }

    func testOverlayStyleAndOptionsOverride() throws {
        let engine = FakeEngine(["/v1/store-sheet": storeSheetReply(), "/v1/match-save": [:]])
        let presenter = SpyPresenter()
        let opts = StoreSheetOptions(appStoreId: "123456789", providerToken: "118", customProductPageId: "abc-page", style: .overlay)
        let r = try XCTUnwrap(open(client(engine), opts, presenter: presenter))
        XCTAssertEqual(r.method, "overlay")
        XCTAssertEqual(presenter.shown.first?.1, .overlay)
        XCTAssertEqual(presenter.shown.first?.0,
                       StoreProduct(appStoreId: "123456789", campaignToken: "autumn-sale", providerToken: "118", customProductPageId: "abc-page"))
    }

    func testHandoffLinkCopiedOnlyWhenAskedAndValid() throws {
        let pb = WritablePasteboard()
        let engine = FakeEngine(["/v1/store-sheet": storeSheetReply(handoff: HANDOFF), "/v1/match-save": [:]])
        XCTAssertEqual(open(client(engine, pasteboard: pb))?.handoffCopied, false)
        XCTAssertTrue(pb.written.isEmpty)
        let r = try XCTUnwrap(open(client(engine, pasteboard: pb), StoreSheetOptions(copyHandoffLink: true)))
        XCTAssertTrue(r.handoffCopied)
        XCTAssertEqual(pb.written, [HANDOFF])
        let bad = FakeEngine(["/v1/store-sheet": storeSheetReply(handoff: "https://evil.example/x"), "/v1/match-save": [:]])
        XCTAssertEqual(open(client(bad, pasteboard: pb), StoreSheetOptions(copyHandoffLink: true))?.handoffCopied, false)
        XCTAssertEqual(pb.written.count, 1)
    }

    func testOfflineStillShowsStoreWhenIdGiven() throws {
        let engine = FakeEngine()
        engine.offline = true
        let r = try XCTUnwrap(open(client(engine), StoreSheetOptions(appStoreId: "6474676842")))
        XCTAssertTrue(r.opened)
        XCTAssertNil(r.clickId)
        XCTAssertEqual(r.reason, "offline")
        XCTAssertFalse(r.matchSaved)
    }

    func testUnknownLinkWithoutIdOpensNothing() throws {
        let engine = FakeEngine(["/v1/store-sheet": ["ok": false, "reason": "not_found"]])
        let presenter = SpyPresenter()
        let r = try XCTUnwrap(open(client(engine), presenter: presenter))
        XCTAssertFalse(r.opened)
        XCTAssertEqual(r.method, "none")
        XCTAssertEqual(r.reason, "not_found")
        XCTAssertTrue(presenter.shown.isEmpty)
    }

    func testPresenterFailureReportsNotShown() throws {
        let engine = FakeEngine(["/v1/store-sheet": storeSheetReply(), "/v1/match-save": [:]])
        let presenter = SpyPresenter()
        presenter.answer = false
        let r = try XCTUnwrap(open(client(engine), presenter: presenter))
        XCTAssertFalse(r.opened)
        XCTAssertEqual(r.reason, "not_shown")
    }

    func testProductHelpers() {
        XCTAssertTrue(StoreSheet.isAppStoreId("6474676842"))
        XCTAssertFalse(StoreSheet.isAppStoreId("id6474676842"))
        XCTAssertFalse(StoreSheet.isAppStoreId(""))
        XCTAssertNil(StoreSheet.product(reply: ["appStoreId": NSNull()], options: StoreSheetOptions()))
        let long = String(repeating: "c", count: 50)
        XCTAssertEqual(StoreSheet.product(reply: ["appStoreId": "1", "campaignToken": long], options: StoreSheetOptions())?.campaignToken?.count, 30)
        XCTAssertEqual(StoreSheet.handoffLink(HANDOFF), HANDOFF)
        XCTAssertNil(StoreSheet.handoffLink("http://hilltop.strait.link/h/AbCdEfGhIjKlMnOpQrStUv"))
        XCTAssertNil(StoreSheet.handoffLink(NSNull()))
    }

    func testStaticEntryPoint() {
        let engine = FakeEngine(["/v1/store-sheet": storeSheetReply(), "/v1/match-save": [:]])
        var out: StoreSheetResult?
        Strait.openStoreSheet(client(engine), url: "https://hilltop.strait.link/promo", presenter: SpyPresenter()) { out = $0 }
        XCTAssertEqual(out?.opened, true)
    }
}
