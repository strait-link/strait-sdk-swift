import XCTest
@testable import StraitSDK

/// Port of sdk-react-native/test/strait.test.ts: the client against a fake
/// engine + clock. The fake transport answers synchronously and callbacks run
/// inline (`callbackQueue: nil`), so every scenario is deterministic.

private let PK = "bk_pub_test_appowner01"
private let ENDPOINT = "https://links.test"
private let device = DeviceFields(screenWidth: 411, pixelRatio: 2.625, language: "en", timezone: "Asia/Kolkata")

/// Fake engine: routes by path, records every call.
final class FakeEngine: StraitTransport {
    struct Call {
        let method: String
        let path: String
        let query: String?
        let body: [String: Any]?
    }
    var routes: [String: [String: Any]]
    var offline = false
    var calls: [Call] = []

    init(_ routes: [String: [String: Any]] = [:]) { self.routes = routes }

    func send(_ request: URLRequest, completion: @escaping (Result<StraitHTTPResponse, Error>) -> Void) {
        let url = request.url!
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        calls.append(Call(method: request.httpMethod ?? "GET", path: url.path, query: url.query, body: body))
        if offline { return completion(.failure(URLError(.notConnectedToInternet))) }
        guard let payload = routes[url.path] else {
            return completion(.success(StraitHTTPResponse(status: 404, data: Data())))
        }
        completion(.success(StraitHTTPResponse(status: 200, data: try! JSONSerialization.data(withJSONObject: payload))))
    }

    func calls(to path: String) -> [Call] { calls.filter { $0.path == path } }
}

final class FakeClock {
    var t: Double = 1_000_000
    func advance(_ ms: Double) { t += ms }
}

final class Harness {
    let clock: FakeClock
    let engine: FakeEngine
    let storage: MemoryStorage
    let strait: StraitLinks
    var events: [LinkEvent] = []

    init(_ engine: FakeEngine, storage: MemoryStorage = MemoryStorage(), linkHosts: [String] = []) {
        self.engine = engine
        self.storage = storage
        let clock = FakeClock()
        self.clock = clock
        strait = StraitLinks(StraitLinksConfig(
            publishableKey: PK, endpoint: ENDPOINT, linkHosts: linkHosts, storage: storage, transport: engine,
            now: { clock.t }, device: { device }, callbackQueue: nil, observeLifecycle: false
        ))
        strait.onLink { [unowned self] in self.events.append($0) }
    }

    func start(_ initial: String? = nil) {
        var done = false
        strait.start(initialURL: initial.flatMap(URL.init(string:))) { done = true }
        XCTAssertTrue(done, "start completes synchronously with the fake engine")
    }
}

private let resolved: [String: [String: Any]] = [
    "/v1/resolve": ["matched": true, "longUrl": "https://shop.example/p/42?color=red", "linkId": "lnk_42", "slug": "sale"],
]

final class DirectLinkTests: XCTestCase {
    func testClosedVerifiedLinkResolvesShortUrl() throws {
        let h = Harness(FakeEngine(resolved))
        h.start("https://links.test/sale")
        XCTAssertEqual(h.events.count, 1)
        let e = try XCTUnwrap(h.events.first)
        XCTAssertEqual(e.kind, .direct)
        XCTAssertEqual(e.route, .appLink)
        XCTAssertEqual(e.appState, .closed)
        XCTAssertTrue(e.matched)
        XCTAssertNil(e.reason)
        XCTAssertEqual(e.rawUrl, "https://links.test/sale")
        XCTAssertEqual(e.url, "https://shop.example/p/42?color=red")
        XCTAssertEqual(e.path, "/p/42")
        XCTAssertEqual(e.params, ["color": "red"])
        XCTAssertEqual(e.linkId, "lnk_42")
        XCTAssertEqual(e.at, 1_000_000)
        let body = try XCTUnwrap(h.engine.calls(to: "/v1/resolve").first?.body)
        XCTAssertEqual(body["publishableKey"] as? String, PK)
        XCTAssertEqual(body["url"] as? String, "https://links.test/sale")
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertNil(body["appId"])
        // Launched by a link: no deferred check.
        XCTAssertTrue(h.engine.calls(to: "/v1/match").isEmpty)
    }

    func testBackgroundResumeThenLink() {
        let h = Harness(FakeEngine(resolved))
        h.start()
        h.strait.onAppState(.background)
        h.clock.advance(60_000)
        h.strait.onAppState(.active)
        h.clock.advance(300)
        h.strait.handle(url: URL(string: "https://links.test/sale")!)
        XCTAssertEqual(h.events.last?.kind, .direct)
        XCTAssertEqual(h.events.last?.appState, .background)
        XCTAssertEqual(h.events.last?.matched, true)
    }

    func testBackgroundLinkBeforeActive() {
        let h = Harness(FakeEngine(resolved))
        h.start()
        h.strait.onAppState(.background)
        h.clock.advance(60_000)
        h.strait.handle(url: URL(string: "https://links.test/sale")!) // delivered before didBecomeActive
        h.strait.onAppState(.active)
        XCTAssertEqual(h.events.last?.appState, .background)
    }

    func testBriefPauseAroundDeliveryIsForeground() {
        let h = Harness(FakeEngine(resolved))
        h.start()
        h.clock.advance(30_000)
        h.strait.onAppState(.inactive)
        h.clock.advance(40)
        h.strait.handle(url: URL(string: "https://links.test/sale")!)
        h.clock.advance(30)
        h.strait.onAppState(.active)
        XCTAssertEqual(h.events.last?.appState, .foreground)
    }

    func testOnScreenIsForeground() {
        let h = Harness(FakeEngine(resolved))
        h.start()
        h.clock.advance(30_000)
        h.strait.handle(url: URL(string: "https://links.test/sale")!)
        XCTAssertEqual(h.events.last?.appState, .foreground)
    }

    func testExplicitTimestampsForAppState() {
        let h = Harness(FakeEngine(resolved))
        h.start()
        h.strait.onAppState(.background, at: h.clock.t - 5_000)
        h.strait.handle(urlString: "https://links.test/sale")
        XCTAssertEqual(h.events.last?.appState, .background)
    }

    func testCustomSchemeCarriesDestinationWithoutNetwork() throws {
        let h = Harness(FakeEngine())
        h.start("straitlink://shop.example/p/42?color=red")
        let e = try XCTUnwrap(h.events.first)
        XCTAssertEqual(e.kind, .direct)
        XCTAssertEqual(e.route, .customScheme)
        XCTAssertEqual(e.appState, .closed)
        XCTAssertTrue(e.matched)
        XCTAssertEqual(e.url, "https://shop.example/p/42?color=red")
        XCTAssertEqual(e.path, "/p/42")
        XCTAssertEqual(e.params, ["color": "red"])
        XCTAssertTrue(h.engine.calls(to: "/v1/resolve").isEmpty)
    }

    func testVerifiedLinkOnOwnSiteIsTheDestination() throws {
        let h = Harness(FakeEngine())
        h.start()
        h.strait.handle(url: URL(string: "https://shop.example/p/7?x=1+2")!)
        let e = try XCTUnwrap(h.events.last)
        XCTAssertEqual(e.route, .appLink)
        XCTAssertTrue(e.matched)
        XCTAssertEqual(e.url, "https://shop.example/p/7?x=1+2")
        XCTAssertEqual(e.params, ["x": "1 2"])
        XCTAssertTrue(h.engine.calls(to: "/v1/resolve").isEmpty)
    }

    func testCustomDomainLinkHostIsResolved() throws {
        let h = Harness(FakeEngine(resolved), linkHosts: ["go.brand.com", "https://Links2.Brand.com"])
        h.start()
        h.strait.handle(url: URL(string: "https://GO.brand.com/sale")!)
        h.strait.handle(url: URL(string: "https://links2.brand.com/sale")!)
        XCTAssertEqual(h.engine.calls(to: "/v1/resolve").count, 2)
        XCTAssertEqual(h.events.last?.url, "https://shop.example/p/42?color=red")
    }

    func testExpiredShortLinkIsReported() throws {
        let h = Harness(FakeEngine(["/v1/resolve": ["matched": false, "reason": "expired"]]))
        h.start("https://links.test/old")
        let e = try XCTUnwrap(h.events.first)
        XCTAssertEqual(e.kind, .direct)
        XCTAssertEqual(e.route, .appLink)
        XCTAssertFalse(e.matched)
        XCTAssertEqual(e.reason, "expired")
        XCTAssertNil(e.url)
    }

    func testNetworkFailureIsReportedNotThrown() throws {
        let engine = FakeEngine(resolved)
        engine.offline = true
        let h = Harness(engine)
        h.start("https://links.test/sale")
        let e = try XCTUnwrap(h.events.first)
        XCTAssertFalse(e.matched)
        XCTAssertEqual(e.reason, "network")
        XCTAssertEqual(e.rawUrl, "https://links.test/sale")
    }

    func testInvalidUrl() throws {
        let h = Harness(FakeEngine())
        h.start()
        h.strait.handle(urlString: "not a url")
        let e = try XCTUnwrap(h.events.last)
        XCTAssertFalse(e.matched)
        XCTAssertEqual(e.reason, "invalid_url")
    }

    func testLateSubscribersGetReplay() throws {
        let h = Harness(FakeEngine())
        h.start("straitlink://shop.example/cart")
        var late: [LinkEvent] = []
        h.strait.onLink { late.append($0) }
        XCTAssertEqual(late.count, 1)
        XCTAssertEqual(late.first?.path, "/cart")
    }

    func testUnsubscribe() {
        let h = Harness(FakeEngine())
        h.storage.setItem("strait.deferredChecked", "1") // not a first launch
        h.start()
        var got = 0
        let sub = h.strait.onLink { _ in got += 1 }
        sub.cancel()
        h.strait.handle(urlString: "straitlink://shop.example/cart")
        XCTAssertEqual(got, 0)
        XCTAssertEqual(h.events.count, 1)
    }

    func testLinkStartFiresBeforeEventWithSameId() throws {
        let h = Harness(FakeEngine(resolved))
        h.storage.setItem("strait.deferredChecked", "1") // not a first launch
        var log: [String] = []
        var startId: String?
        h.strait.onLinkStart { s in
            log.append("start")
            startId = s.id
            XCTAssertEqual(s.kind, .direct)
            XCTAssertEqual(s.rawUrl, "https://links.test/sale")
        }
        h.strait.onLink { _ in log.append("event") }
        h.start()
        h.strait.handle(url: URL(string: "https://links.test/sale")!)
        XCTAssertEqual(log, ["start", "event"])
        XCTAssertEqual(startId, h.events.last?.id)
    }

    func testUserActivity() {
        let h = Harness(FakeEngine(resolved))
        h.start()
        let web = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        web.webpageURL = URL(string: "https://links.test/sale")
        XCTAssertTrue(h.strait.handle(userActivity: web))
        XCTAssertEqual(h.events.last?.linkId, "lnk_42")
        XCTAssertFalse(h.strait.handle(userActivity: NSUserActivity(activityType: "com.example.other")))
    }
}

final class DeferredLinkTests: XCTestCase {
    private let matchHit: [String: [String: Any]] = [
        "/v1/match": ["matched": true, "longUrl": "https://shop.example/promo/DIWALI20?c=1", "linkId": "lnk_7", "matchMethod": "fingerprint"],
    ]

    func testFirstLaunchFingerprintMatch() throws {
        let h = Harness(FakeEngine(matchHit))
        var starts: [LinkStart] = []
        h.strait.onLinkStart { starts.append($0) }
        h.start()
        let e = try XCTUnwrap(h.events.first)
        XCTAssertEqual(e.kind, .deferred)
        XCTAssertEqual(e.route, .fingerprint)
        XCTAssertEqual(e.appState, .closed)
        XCTAssertTrue(e.matched)
        XCTAssertEqual(e.url, "https://shop.example/promo/DIWALI20?c=1")
        XCTAssertEqual(e.path, "/promo/DIWALI20")
        XCTAssertEqual(e.params, ["c": "1"])
        XCTAssertEqual(e.linkId, "lnk_7")
        XCTAssertEqual(starts.map(\.id), [e.id])
        XCTAssertEqual(starts.first?.kind, .deferred)
        let body = try XCTUnwrap(h.engine.calls(to: "/v1/match").first?.body)
        XCTAssertEqual(body["publishableKey"] as? String, PK)
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["screenWidth"] as? Int, 411)
        XCTAssertEqual(body["pixelRatio"] as? Double, 2.625)
        XCTAssertEqual(body["language"] as? String, "en")
        XCTAssertEqual(body["timezone"] as? String, "Asia/Kolkata")
        XCTAssertEqual(h.storage.getItem("strait.deferredChecked"), "1")
    }

    func testNoMatchIsReported() throws {
        let h = Harness(FakeEngine(["/v1/match": ["matched": false, "matchMethod": "none"]]))
        h.start()
        let e = try XCTUnwrap(h.events.first)
        XCTAssertEqual(e.kind, .deferred)
        XCTAssertEqual(e.route, .fingerprint)
        XCTAssertFalse(e.matched)
        XCTAssertEqual(e.reason, "no_match")
    }

    func testRunsOnlyOncePerInstall() {
        let storage = MemoryStorage()
        let first = Harness(FakeEngine(matchHit), storage: storage)
        first.start()
        XCTAssertEqual(first.events.filter { $0.kind == .deferred }.count, 1)
        let second = Harness(FakeEngine(matchHit), storage: storage)
        second.start()
        XCTAssertTrue(second.events.filter { $0.kind == .deferred }.isEmpty)
        XCTAssertTrue(second.engine.calls(to: "/v1/match").isEmpty)
    }

    func testFirstLaunchOpenedByLinkSkipsDeferredButMarksDone() {
        let h = Harness(FakeEngine(matchHit))
        h.start("straitlink://shop.example/cart")
        XCTAssertEqual(h.events.map(\.kind), [.direct])
        XCTAssertTrue(h.engine.calls(to: "/v1/match").isEmpty)
        XCTAssertEqual(h.storage.getItem("strait.deferredChecked"), "1")
    }

    func testNetworkFailure() throws {
        let engine = FakeEngine(matchHit)
        engine.offline = true
        let h = Harness(engine)
        h.start()
        let e = try XCTUnwrap(h.events.first)
        XCTAssertEqual(e.kind, .deferred)
        XCTAssertFalse(e.matched)
        XCTAssertEqual(e.reason, "network")
    }

    func testCheckDeferredReRunsWithoutTouchingFlag() {
        let h = Harness(FakeEngine(matchHit))
        h.storage.setItem("strait.deferredChecked", "1")
        h.start()
        XCTAssertTrue(h.events.isEmpty)
        var got: LinkEvent?
        h.strait.checkDeferred { got = $0 }
        XCTAssertEqual(got?.matched, true)
        XCTAssertEqual(got, h.events.last)
    }
}

final class FingerprintAndEventTests: XCTestCase {
    func testReportAndCompareFingerprint() throws {
        let engine = FakeEngine(["/v1/debug/fingerprint": ["extHash": "abc", "coreHash": "def", "inputs": [String: Any]()]])
        let h = Harness(engine)
        var reported: [String: Any]?
        h.strait.reportFingerprint { reported = $0 }
        XCTAssertEqual(reported?["extHash"] as? String, "abc")
        let post = try XCTUnwrap(engine.calls.first { $0.method == "POST" && $0.path == "/v1/debug/fingerprint" })
        XCTAssertEqual(post.body?["publishableKey"] as? String, PK)
        XCTAssertEqual(post.body?["origin"] as? String, "app")
        XCTAssertEqual(post.body?["screenWidth"] as? Int, 411)
        XCTAssertEqual(post.body?["timezone"] as? String, "Asia/Kolkata")

        var compared: [String: Any]?
        h.strait.compareFingerprint { compared = $0 }
        XCTAssertEqual(compared?["coreHash"] as? String, "def")
        let get = try XCTUnwrap(engine.calls.first { $0.method == "GET" && $0.path == "/v1/debug/fingerprint" })
        XCTAssertEqual(get.query, "publishableKey=\(PK)")
        XCTAssertNil(get.body)
    }

    func testFingerprintOfflineIsNil() {
        let engine = FakeEngine()
        engine.offline = true
        let h = Harness(engine)
        var called = false
        h.strait.reportFingerprint { XCTAssertNil($0); called = true }
        XCTAssertTrue(called)
    }

    func testTrackEventSendsPublishableKey() throws {
        let engine = FakeEngine(["/v1/event": ["ok": true]])
        let h = Harness(engine)
        var ok: Bool?
        h.strait.trackEvent("purchase", value: 49.99, currency: "USD", linkId: "lnk_42") { ok = $0 }
        XCTAssertEqual(ok, true)
        let body = try XCTUnwrap(engine.calls.last?.body)
        XCTAssertEqual(body["publishableKey"] as? String, PK)
        XCTAssertEqual(body["event"] as? String, "purchase")
        XCTAssertEqual(body["value"] as? Double, 49.99)
        XCTAssertEqual(body["currency"] as? String, "USD")
        XCTAssertEqual(body["linkId"] as? String, "lnk_42")
        XCTAssertEqual(body["platform"] as? String, "ios")
    }

    func testTrackEventFailureIsFalse() {
        let engine = FakeEngine()
        engine.offline = true
        let h = Harness(engine)
        var ok: Bool?
        h.strait.trackEvent("purchase") { ok = $0 }
        XCTAssertEqual(ok, false)
        let rejected = Harness(FakeEngine()) // 404
        rejected.strait.trackEvent("purchase") { ok = $0 }
        XCTAssertEqual(ok, false)
    }
}
