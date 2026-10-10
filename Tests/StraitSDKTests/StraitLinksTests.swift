import XCTest
@testable import StraitSDK

/// Port of sdk-react-native/test/strait.test.ts: the client against a fake
/// engine + clock. The fake transport answers synchronously and callbacks run
/// inline (`callbackQueue: nil`), so every scenario is deterministic.

private let PK = "bk_pub_test_appowner01"
private let ENDPOINT = "https://links.test"
private let device = DeviceFields(screenWidth: 411, pixelRatio: 2.625, language: "en", timezone: "Asia/Kolkata")

/// Fake engine: routes by path, records every call. `modes` overrides how a
/// path answers (offline, never, or a status code) and can change mid-test.
final class FakeEngine: StraitTransport {
    enum Mode {
        case offline, hang
        case status(Int)
    }
    struct Call {
        let method: String
        let path: String
        let query: String?
        let body: [String: Any]?
    }
    var routes: [String: [String: Any]]
    var offline = false
    var modes: [String: Mode] = [:]
    var calls: [Call] = []

    init(_ routes: [String: [String: Any]] = [:]) { self.routes = routes }

    func send(_ request: URLRequest, completion: @escaping (Result<StraitHTTPResponse, Error>) -> Void) {
        let url = request.url!
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        calls.append(Call(method: request.httpMethod ?? "GET", path: url.path, query: url.query, body: body))
        if offline { return completion(.failure(URLError(.notConnectedToInternet))) }
        switch modes[url.path] {
        case .offline?: return completion(.failure(URLError(.notConnectedToInternet)))
        case .hang?: return
        case let .status(code)?:
            let payload = routes[url.path] ?? [:]
            return completion(.success(StraitHTTPResponse(status: code, data: try! JSONSerialization.data(withJSONObject: payload))))
        case nil: break
        }
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

    let pasteboard: SpyPasteboard

    init(_ engine: FakeEngine, storage: MemoryStorage = MemoryStorage(), linkHosts: [String] = [],
         pasteboard: SpyPasteboard = SpyPasteboard(), platform: String = "ios") {
        self.engine = engine
        self.pasteboard = pasteboard
        self.storage = storage
        let clock = FakeClock()
        self.clock = clock
        strait = StraitLinks(StraitLinksConfig(
            publishableKey: PK, endpoint: ENDPOINT, linkHosts: linkHosts, storage: storage, transport: engine,
            now: { clock.t }, device: { device }, platform: platform, callbackQueue: nil, observeLifecycle: false,
            pasteboard: pasteboard
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

// MARK: - Contract B14: every link open reported exactly once (+ B6 revision)

/// Port of sdk-react-native/test/opens.test.ts. The Play Install Referrer case
/// (B7) is Android-only and has no iOS equivalent.
private let CLICK = "3f2a9c1e-7b4d-4e8a-9c0f-1a2b3c4d5e6f"
private let accepted: [String: Any] = ["ok": true, "duplicate": false]
private let resolvedRecorded: [String: Any] = [
    "matched": true, "longUrl": "https://shop.example/p/42", "linkId": "lnk_42", "slug": "sale", "recorded": true,
]
private let noMatch: [String: Any] = ["matched": false, "matchMethod": "none"]

private func returning() -> MemoryStorage {
    let s = MemoryStorage()
    s.setItem("strait.deferredChecked", "1") // not the first launch
    return s
}

private func isOpenId(_ id: String) -> Bool {
    id.range(of: "^o_[a-z0-9]+_[a-z0-9]{12}$", options: .regularExpression) != nil
}

private func pending(_ h: Harness) -> Int {
    var n = -1
    h.strait.pendingOpenReports { n = $0 }
    return n
}

final class HandOffOpenTests: XCTestCase {
    func testReportsOpenWithTapIdAppNeverSeesIt() throws {
        let engine = FakeEngine(["/v1/open": accepted])
        engine.modes["/v1/open"] = .status(202)
        let h = Harness(engine, storage: returning())
        h.start()
        h.strait.onAppState(.background); h.clock.advance(5000); h.strait.onAppState(.active); h.clock.advance(200)
        h.strait.handle(urlString: "straitlink://shop.example/p/42?color=red&strait_click=\(CLICK)")
        let e = try XCTUnwrap(h.events.last)
        XCTAssertEqual(e.route, .customScheme)
        XCTAssertEqual(e.url, "https://shop.example/p/42?color=red")
        XCTAssertEqual(e.params, ["color": "red"])
        XCTAssertEqual(e.appState, .background)
        XCTAssertTrue(isOpenId(e.id), e.id)
        let opens = engine.calls(to: "/v1/open")
        XCTAssertEqual(opens.count, 1)
        let body = try XCTUnwrap(opens.first?.body)
        XCTAssertEqual(body["publishableKey"] as? String, PK)
        XCTAssertEqual(body["openId"] as? String, e.id)
        XCTAssertEqual(body["kind"] as? String, "direct")
        XCTAssertEqual(body["route"] as? String, "custom_scheme")
        XCTAssertEqual(body["appState"] as? String, "background")
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["url"] as? String, "https://shop.example/p/42") // B18: no query
        XCTAssertEqual(body["clickId"] as? String, CLICK)
        XCTAssertEqual(body["matched"] as? Bool, true)
        XCTAssertEqual(body["firstLaunch"] as? Bool, false)
        XCTAssertEqual(body["at"] as? Double, e.at)
    }

    func testNavigationNeverWaitsForTheReport() {
        let engine = FakeEngine()
        engine.modes["/v1/open"] = .hang
        let h = Harness(engine, storage: returning())
        h.start("straitlink://shop.example/p/1?strait_click=\(CLICK)")
        XCTAssertEqual(h.events.count, 1)
        XCTAssertEqual(h.events.first?.url, "https://shop.example/p/1")
    }

    func testOwnHttpsLinkIsReportedWithoutTapId() throws {
        let engine = FakeEngine(["/v1/open": accepted])
        let h = Harness(engine, storage: returning())
        h.start("https://shop.example/p/9")
        let body = try XCTUnwrap(engine.calls(to: "/v1/open").first?.body)
        XCTAssertEqual(body["route"] as? String, "app_link")
        XCTAssertEqual(body["url"] as? String, "https://shop.example/p/9")
        XCTAssertEqual(body["appState"] as? String, "closed")
        XCTAssertNil(body["clickId"])
    }
}

final class ShortLinkOpenTests: XCTestCase {
    func testResolveCarriesOpenIdAndNothingElseOnceRecorded() throws {
        let engine = FakeEngine(["/v1/resolve": resolvedRecorded, "/v1/open": accepted])
        let h = Harness(engine, storage: returning())
        h.start("https://links.test/sale")
        let e = try XCTUnwrap(h.events.first)
        let body = try XCTUnwrap(engine.calls(to: "/v1/resolve").first?.body)
        XCTAssertEqual(body["openId"] as? String, e.id)
        XCTAssertEqual(body["appState"] as? String, "closed")
        XCTAssertEqual(body["firstLaunch"] as? Bool, false)
        XCTAssertEqual(body["at"] as? Double, e.at)
        XCTAssertTrue(engine.calls(to: "/v1/open").isEmpty)
    }

    func testNotRecordedIsRetriedViaOpenWithSameOpenId() throws {
        var notRecorded = resolvedRecorded
        notRecorded["recorded"] = false
        let engine = FakeEngine(["/v1/resolve": notRecorded, "/v1/open": accepted])
        let h = Harness(engine, storage: returning())
        h.start("https://links.test/sale")
        let e = try XCTUnwrap(h.events.first)
        XCTAssertTrue(e.matched)
        let body = try XCTUnwrap(engine.calls(to: "/v1/open").first?.body)
        XCTAssertEqual(body["openId"] as? String, e.id)
        XCTAssertEqual(body["route"] as? String, "app_link")
        XCTAssertEqual(body["url"] as? String, "https://links.test/sale")
        XCTAssertEqual(body["matched"] as? Bool, true)
        XCTAssertEqual(body["linkId"] as? String, "lnk_42")
    }

    func testOfflineSavedThenSentWhenAppComesBack() throws {
        let engine = FakeEngine()
        engine.modes = ["/v1/resolve": .offline, "/v1/open": .offline]
        let h = Harness(engine, storage: returning())
        h.start()
        h.strait.handle(urlString: "https://links.test/sale")
        let e = try XCTUnwrap(h.events.last)
        XCTAssertFalse(e.matched)
        XCTAssertEqual(e.reason, "network")
        XCTAssertEqual(pending(h), 1)
        // network returns; user leaves and comes back
        engine.routes["/v1/open"] = accepted
        engine.modes["/v1/open"] = .status(202)
        h.strait.onAppState(.background); h.clock.advance(10_000); h.strait.onAppState(.active)
        let sent = engine.calls(to: "/v1/open").filter { $0.body?["openId"] as? String == e.id }
        let body = try XCTUnwrap(sent.last?.body)
        XCTAssertEqual(body["route"] as? String, "app_link")
        XCTAssertEqual(body["url"] as? String, "https://links.test/sale")
        XCTAssertEqual(body["matched"] as? Bool, false)
        XCTAssertEqual(body["reason"] as? String, "network")
        XCTAssertEqual(pending(h), 0)
    }
}

final class OpenQueueTests: XCTestCase {
    func testKeepsOn5xxAnd429DropsOn4xx() {
        let engine = FakeEngine()
        engine.modes["/v1/open"] = .status(503)
        let h = Harness(engine, storage: returning())
        h.start()
        h.strait.handle(urlString: "straitlink://a.b/1")
        XCTAssertEqual(pending(h), 1)
        engine.modes["/v1/open"] = .status(429)
        var flushed = false
        h.strait.flushOpenReports { flushed = true }
        XCTAssertTrue(flushed)
        XCTAssertEqual(pending(h), 1)
        engine.routes["/v1/open"] = ["error": "bad"]
        engine.modes["/v1/open"] = .status(400)
        h.strait.flushOpenReports()
        XCTAssertEqual(pending(h), 0)
    }

    func testSurvivesRestartAndIsSentOnNextStart() {
        let storage = returning()
        let e1 = FakeEngine()
        e1.modes["/v1/open"] = .offline
        let first = Harness(e1, storage: storage)
        first.start()
        first.strait.handle(urlString: "straitlink://a.b/1")
        first.strait.handle(urlString: "straitlink://a.b/2")
        XCTAssertEqual(pending(first), 2)
        XCTAssertNotNil(storage.getItem("strait.pendingOpens"))
        first.strait.stop()

        let e2 = FakeEngine(["/v1/open": accepted])
        let second = Harness(e2, storage: storage)
        second.start()
        XCTAssertEqual(e2.calls(to: "/v1/open").map { $0.body?["url"] as? String }, ["https://a.b/1", "https://a.b/2"])
        XCTAssertEqual(pending(second), 0)
    }

    func testSuccessfulReportAlsoSendsEarlierOnes() {
        let engine = FakeEngine()
        engine.modes["/v1/open"] = .offline
        let h = Harness(engine, storage: returning())
        h.start()
        h.strait.handle(urlString: "straitlink://a.b/old")
        engine.routes["/v1/open"] = accepted
        engine.modes["/v1/open"] = nil
        h.strait.handle(urlString: "straitlink://a.b/new")
        XCTAssertEqual(pending(h), 0)
        let oldIds = Set(engine.calls(to: "/v1/open").filter { $0.body?["url"] as? String == "https://a.b/old" }
            .compactMap { $0.body?["openId"] as? String })
        XCTAssertEqual(oldIds.count, 1)
    }

    func testEveryOpenHasItsOwnId() {
        let h = Harness(FakeEngine(["/v1/open": accepted]), storage: returning())
        h.start()
        for i in 0..<5 { h.strait.handle(urlString: "straitlink://a.b/\(i)") }
        XCTAssertEqual(Set(h.events.map(\.id)).count, 5)
    }
}

final class FirstLaunchTests: XCTestCase {
    func testFirstLaunchOpenedByLinkCountsAsInstall() throws {
        let engine = FakeEngine(["/v1/resolve": resolvedRecorded])
        let h = Harness(engine)
        h.start("https://links.test/sale")
        XCTAssertEqual(engine.calls(to: "/v1/resolve").first?.body?["firstLaunch"] as? Bool, true)
        XCTAssertTrue(engine.calls(to: "/v1/referrer").isEmpty)
        XCTAssertTrue(engine.calls(to: "/v1/match").isEmpty)
        XCTAssertEqual(h.storage.getItem("strait.deferredChecked"), "1")
    }

    func testFingerprintSendsOpenId() throws {
        let engine = FakeEngine(["/v1/match": noMatch])
        let h = Harness(engine)
        h.start()
        let e = try XCTUnwrap(h.events.first)
        let body = try XCTUnwrap(engine.calls(to: "/v1/match").first?.body)
        XCTAssertEqual(body["openId"] as? String, e.id)
        XCTAssertEqual(body["at"] as? Double, e.at)
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["screenWidth"] as? Int, 411)
        XCTAssertEqual(body["pixelRatio"] as? Double, 2.625)
        XCTAssertEqual(body["language"] as? String, "en")
        XCTAssertEqual(body["timezone"] as? String, "Asia/Kolkata")
    }

    func testOfflineNotMarkedDoneSoNextLaunchChecksAgain() throws {
        let storage = MemoryStorage()
        let e1 = FakeEngine()
        e1.modes["/v1/match"] = .offline
        let first = Harness(e1, storage: storage)
        first.start()
        XCTAssertEqual(first.events.first?.kind, .deferred)
        XCTAssertEqual(first.events.first?.reason, "network")
        XCTAssertNil(storage.getItem("strait.deferredChecked"))

        let e2 = FakeEngine(["/v1/match": noMatch])
        Harness(e2, storage: storage).start()
        XCTAssertEqual(e2.calls(to: "/v1/match").count, 1)
        XCTAssertEqual(storage.getItem("strait.deferredChecked"), "1")

        let e3 = FakeEngine(["/v1/match": noMatch])
        Harness(e3, storage: storage).start()
        XCTAssertTrue(e3.calls(to: "/v1/match").isEmpty) // once per install
    }

    func testServerErrorCountsAsNotAnswered() {
        let storage = MemoryStorage()
        let engine = FakeEngine()
        engine.modes["/v1/match"] = .status(502)
        let h = Harness(engine, storage: storage)
        h.start()
        XCTAssertEqual(h.events.first?.reason, "network")
        XCTAssertNil(storage.getItem("strait.deferredChecked"))
    }

    func testTimestampsAreSentAsWholeMilliseconds() throws {
        let engine = FakeEngine(["/v1/match": noMatch, "/v1/resolve": resolvedRecorded])
        engine.modes["/v1/open"] = .offline
        let h = Harness(engine)
        h.clock.t = 1_800_000_000_123.75
        h.start()
        h.strait.handle(urlString: "https://links.test/sale")
        h.strait.handle(urlString: "straitlink://a.b/1")
        let bodies = [engine.calls(to: "/v1/match").first?.body, engine.calls(to: "/v1/resolve").first?.body,
                      engine.calls(to: "/v1/open").first?.body]
        for body in bodies {
            let at = try XCTUnwrap(body?["at"] as? NSNumber)
            XCTAssertEqual(at.doubleValue, 1_800_000_000_123)
        }
        let saved = try XCTUnwrap(h.storage.getItem("strait.pendingOpens"))
        XCTAssertTrue(saved.contains("\"at\":1800000000123"), saved)
    }

    func testDebugReCheckNeverRecordsAnInstall() {
        let engine = FakeEngine(["/v1/match": noMatch])
        let h = Harness(engine, storage: returning())
        h.start()
        var got: LinkEvent?
        h.strait.checkDeferred { got = $0 }
        XCTAssertNotNil(got)
        XCTAssertEqual(engine.calls(to: "/v1/match").count, 1)
        XCTAssertNil(engine.calls(to: "/v1/match").first?.body?["openId"])
        XCTAssertNil(engine.calls(to: "/v1/match").first?.body?["at"])
    }
}

// MARK: - Contract B15: conversion events carry the tap id

/// Port of the B15 tests in sdk-react-native/test/strait.test.ts. The Play
/// referrer case is Android-only.
private let TAP = "3f2a9c1e-7b4d-4e8a-9c0f-1a2b3c4d5e6f"
private let OTHER_TAP = "11111111-2222-4333-8444-555555555555"
private let DAY: Double = 24 * 60 * 60 * 1000

final class EventClickIdTests: XCTestCase {
    private func lastEvent(_ engine: FakeEngine) -> [String: Any]? { engine.calls(to: "/v1/event").last?.body }

    func testHandOffTapIsRememberedAndAttached() throws {
        let engine = FakeEngine(["/v1/event": ["ok": true], "/v1/open": ["ok": true]])
        let h = Harness(engine)
        h.start("straitlink://shop.example/p/42?strait_click=\(TAP)")
        h.clock.advance(DAY)
        var ok: Bool?
        h.strait.trackEvent("purchase", value: 5, currency: "USD") { ok = $0 }
        XCTAssertEqual(ok, true)
        XCTAssertEqual(lastEvent(engine)?["clickId"] as? String, TAP)
        let stored = try XCTUnwrap(h.storage.getItem(StraitLinks.tapKey))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any])
        XCTAssertEqual(obj["clickId"] as? String, TAP)
        XCTAssertEqual(obj["at"] as? Double, 1_000_000)
    }

    func testNotAfterSevenDays() {
        let engine = FakeEngine(["/v1/event": ["ok": true], "/v1/open": ["ok": true]])
        let h = Harness(engine)
        h.start("straitlink://shop.example/p/42?strait_click=\(TAP)")
        h.clock.advance(7 * DAY + 1)
        h.strait.trackEvent("purchase")
        XCTAssertNotNil(lastEvent(engine))
        XCTAssertNil(lastEvent(engine)?["clickId"])
    }

    func testExplicitClickIdOverrides() {
        let engine = FakeEngine(["/v1/event": ["ok": true], "/v1/open": ["ok": true]])
        let h = Harness(engine)
        h.start("straitlink://shop.example/p/42?strait_click=\(TAP)")
        h.strait.trackEvent("purchase", clickId: OTHER_TAP)
        XCTAssertEqual(lastEvent(engine)?["clickId"] as? String, OTHER_TAP)
    }

    func testNoRememberedTap() {
        let engine = FakeEngine(["/v1/event": ["ok": true], "/v1/match": ["matched": false]])
        let h = Harness(engine)
        h.start()
        h.strait.trackEvent("signup")
        XCTAssertNotNil(lastEvent(engine))
        XCTAssertNil(lastEvent(engine)?["clickId"])
    }

    func testNewerShortLinkOpenWithoutReplyTapIdForgetsOlderTap() {
        var routes = resolved
        routes["/v1/event"] = ["ok": true]
        routes["/v1/open"] = ["ok": true]
        let engine = FakeEngine(routes)
        let h = Harness(engine)
        h.start("straitlink://shop.example/p/42?strait_click=\(TAP)")
        h.strait.handle(urlString: "https://links.test/sale")
        h.strait.trackEvent("purchase")
        XCTAssertNil(lastEvent(engine)?["clickId"])
    }

    func testB16ShortLinkOpenRemembersReplyTapId() {
        var reply = resolved["/v1/resolve"]!
        reply["recorded"] = true
        reply["clickId"] = TAP.uppercased()
        let engine = FakeEngine(["/v1/resolve": reply, "/v1/event": ["ok": true], "/v1/open": ["ok": true]])
        let h = Harness(engine)
        h.start("straitlink://shop.example/p/42?strait_click=\(OTHER_TAP)")
        h.strait.handle(urlString: "https://links.test/sale")
        h.strait.trackEvent("purchase")
        XCTAssertEqual(lastEvent(engine)?["clickId"] as? String, TAP)
    }

    func testB16FingerprintMatchRemembersReplyTapId() {
        let storage = MemoryStorage()
        storage.setItem(StraitLinks.tapKey, rememberTap(OTHER_TAP, at: 1_000_000))
        let engine = FakeEngine([
            "/v1/event": ["ok": true],
            "/v1/match": ["matched": true, "longUrl": "https://shop.example/p/7", "linkId": "lnk_7", "clickId": TAP],
        ])
        let h = Harness(engine, storage: storage)
        h.start()
        h.strait.trackEvent("purchase")
        XCTAssertEqual(lastEvent(engine)?["clickId"] as? String, TAP)
    }

    func testB16MalformedReplyTapIdForgets() {
        var reply = resolved["/v1/resolve"]!
        reply["clickId"] = "nope"
        let engine = FakeEngine(["/v1/resolve": reply, "/v1/event": ["ok": true], "/v1/open": ["ok": true]])
        let h = Harness(engine)
        h.start("straitlink://shop.example/p/42?strait_click=\(TAP)")
        h.strait.handle(urlString: "https://links.test/sale")
        h.strait.trackEvent("purchase")
        XCTAssertNil(lastEvent(engine)?["clickId"])
    }

    func testFingerprintMatchWithoutReplyTapIdForgetsOlderTap() {
        let storage = MemoryStorage()
        storage.setItem(StraitLinks.tapKey, rememberTap(TAP, at: 1_000_000))
        let engine = FakeEngine([
            "/v1/event": ["ok": true],
            "/v1/match": ["matched": true, "longUrl": "https://shop.example/p/7", "linkId": "lnk_7"],
        ])
        let h = Harness(engine, storage: storage)
        h.start()
        h.strait.trackEvent("purchase")
        XCTAssertNil(lastEvent(engine)?["clickId"])
    }
}

/// Contract B18: no query or fragment leaves the device or reaches storage;
/// expired remembered taps are deleted, not only ignored.
final class PrivacyTests: XCTestCase {
    private let DAY: Double = 24 * 3600 * 1000

    private func returning() -> MemoryStorage {
        let s = MemoryStorage()
        s.setItem(StraitLinks.deferredFlag, "1")
        return s
    }

    func testOpenReportKeepsOnlyHostPathAndUtmSource() throws {
        let engine = FakeEngine(["/v1/open": ["ok": true]])
        let h = Harness(engine, storage: returning())
        h.start()
        h.strait.handle(urlString: "https://shop.example/p/42?email=jo%40x.com&utm_source=sms#reset-token")
        let e = try XCTUnwrap(h.events.last)
        XCTAssertEqual(e.url, "https://shop.example/p/42?email=jo%40x.com&utm_source=sms#reset-token")
        XCTAssertEqual(e.params, ["email": "jo@x.com", "utm_source": "sms"])
        XCTAssertEqual(engine.calls(to: "/v1/open").first?.body?["url"] as? String, "https://shop.example/p/42?utm_source=sms")
    }

    func testFailedShortLinkIsResolvedAndQueuedWithoutQuery() throws {
        let engine = FakeEngine()
        engine.offline = true
        let h = Harness(engine, storage: returning())
        h.start()
        h.strait.handle(urlString: "https://links.test/sale?session=s3cr3t&utm_source=wa#frag")
        XCTAssertEqual(engine.calls(to: "/v1/resolve").first?.body?["url"] as? String, "https://links.test/sale?utm_source=wa")
        let saved = try XCTUnwrap(h.storage.getItem(StraitLinks.queueKey))
        XCTAssertFalse(saved.contains("s3cr3t"))
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [[String: Any]])
        XCTAssertEqual(list.first?["url"] as? String, "https://links.test/sale?utm_source=wa")
    }

    func testOlderQueuedReportsAreStrippedBeforeSendingOrSaving() throws {
        let storage = returning()
        storage.setItem(StraitLinks.queueKey, """
        [{"openId":"o_old_aaaaaaaaaaaa","kind":"direct","route":"app_link","appState":"closed","platform":"ios","url":"https://shop.example/p?token=abc#x","matched":true,"firstLaunch":false,"at":999000}]
        """)
        let engine = FakeEngine()
        engine.offline = true
        let h = Harness(engine, storage: storage)
        h.start()
        h.strait.flushOpenReports()
        XCTAssertEqual(engine.calls(to: "/v1/open").first?.body?["url"] as? String, "https://shop.example/p")
        XCTAssertFalse(try XCTUnwrap(storage.getItem(StraitLinks.queueKey)).contains("token"))
    }

    func testExpiredTapIsDeletedAtStart() {
        let storage = returning()
        storage.setItem(StraitLinks.tapKey, rememberTap(TAP, at: 1_000_000 - 8 * DAY))
        let h = Harness(FakeEngine(), storage: storage)
        h.start()
        XCTAssertEqual(storage.getItem(StraitLinks.tapKey), "")
    }

    func testTapThatExpiresWhileRunningIsDeletedByTrackEventAndNotSent() {
        let storage = returning()
        storage.setItem(StraitLinks.tapKey, rememberTap(TAP, at: 1_000_000))
        let engine = FakeEngine(["/v1/event": ["ok": true]])
        let h = Harness(engine, storage: storage)
        h.start()
        XCTAssertTrue(storage.getItem(StraitLinks.tapKey)?.contains(TAP) == true)
        h.clock.advance(7 * DAY + 1)
        h.strait.trackEvent("purchase")
        XCTAssertNil(engine.calls(to: "/v1/event").first?.body?["clickId"])
        XCTAssertEqual(storage.getItem(StraitLinks.tapKey), "")
    }

    func testValidTapIsKeptAndSent() {
        let storage = returning()
        storage.setItem(StraitLinks.tapKey, rememberTap(TAP, at: 1_000_000 - 1000))
        let engine = FakeEngine(["/v1/event": ["ok": true]])
        let h = Harness(engine, storage: storage)
        h.start()
        h.strait.trackEvent("purchase")
        XCTAssertEqual(engine.calls(to: "/v1/event").first?.body?["clickId"] as? String, TAP)
        XCTAssertTrue(storage.getItem(StraitLinks.tapKey)?.contains(TAP) == true)
    }
}


// MARK: - Clipboard boost (B19)

/// Records every clipboard access. Answers synchronously.
final class SpyPasteboard: StraitPasteboard {
    var probableURL: Bool
    var text: String?
    private(set) var detectCalls = 0
    private(set) var readCalls = 0
    init(probableURL: Bool = true, text: String? = nil) {
        self.probableURL = probableURL
        self.text = text
    }
    func hasProbableWebURL(completion: @escaping (Bool) -> Void) {
        detectCalls += 1
        completion(probableURL)
    }
    func readString() -> String? {
        readCalls += 1
        return text
    }
    var touched: Int { detectCalls + readCalls }
}

private let TOKEN = "AbCdEfGhIjKlMnOpQrStUv"
private let HANDOFF = "https://links.test/h/\(TOKEN)"
private let CLAIM_TAP = "3f2a9c1e-7b4d-4e8a-9c0f-1a2b3c4d5e6f"
private let claimed: [String: Any] = [
    "matched": true, "longUrl": "https://shop.example/promo/42?x=1", "linkId": "lnk_42",
    "clickId": CLAIM_TAP, "matchMethod": "clipboard",
]

private let bothOn: [String: Any] = ["deviceMatching": true, "pasteHandoff": true]
/// /v1/match found nothing; the workspace has paste handoff on (device matching on too).
private let noMatchPaste: [String: Any] = ["matched": false, "matchMethod": "none", "ios": bothOn]
/// /v1/match found nothing; the workspace has device matching only.
private let noMatchDeviceOnly: [String: Any] = ["matched": false, "matchMethod": "none", "ios": ["deviceMatching": true, "pasteHandoff": false]]

final class ClipboardBoostTests: XCTestCase {
    func testPasteHandoffOffInTheReplyNeverTouchesTheClipboard() throws {
        let spy = SpyPasteboard(probableURL: true, text: HANDOFF)
        let h = Harness(FakeEngine(["/v1/match": noMatchDeviceOnly, "/v1/handoff/claim": claimed]), pasteboard: spy)
        h.start()
        h.strait.checkDeferred()
        h.strait.reportFingerprint()
        h.strait.handle(urlString: "https://shop.example/p/1")
        XCTAssertEqual(spy.detectCalls, 0)
        XCTAssertEqual(spy.readCalls, 0)
        XCTAssertTrue(h.engine.calls(to: "/v1/handoff/claim").isEmpty)
        XCTAssertEqual(h.engine.calls(to: "/v1/match").count, 2)
    }

    func testDebugCheckDeferredNeverTouchesTheClipboardEvenWithPasteOn() throws {
        let spy = SpyPasteboard(probableURL: true, text: HANDOFF)
        let storage = MemoryStorage()
        storage.setItem(StraitLinks.deferredFlag, "1")
        let h = Harness(FakeEngine(["/v1/match": noMatchPaste, "/v1/handoff/claim": claimed]), storage: storage, pasteboard: spy)
        h.start()
        h.strait.checkDeferred()
        XCTAssertEqual(spy.touched, 0)
        XCTAssertTrue(h.engine.calls(to: "/v1/handoff/claim").isEmpty)
    }

    func testNoProbableURLMeansNoRead() throws {
        let spy = SpyPasteboard(probableURL: false, text: HANDOFF)
        let h = Harness(FakeEngine(["/v1/match": noMatchPaste]), pasteboard: spy)
        h.start()
        XCTAssertEqual(spy.detectCalls, 1)
        XCTAssertEqual(spy.readCalls, 0, "read (the paste prompt) only when a URL is likely")
        XCTAssertTrue(h.engine.calls(to: "/v1/handoff/claim").isEmpty)
        XCTAssertEqual(h.engine.calls(to: "/v1/match").count, 1)
    }

    func testPasteHandoffIsIOSOnly() throws {
        let spy = SpyPasteboard(probableURL: true, text: HANDOFF)
        let h = Harness(FakeEngine(["/v1/match": noMatchPaste]), pasteboard: spy, platform: "android")
        h.start()
        XCTAssertEqual(spy.touched, 0)
    }

    func testClaimMatchIsExactAndRemembersTheTap() throws {
        let spy = SpyPasteboard(probableURL: true, text: "  \(HANDOFF)\n")
        let storage = MemoryStorage()
        let h = Harness(FakeEngine(["/v1/match": noMatchPaste, "/v1/handoff/claim": claimed]), storage: storage, pasteboard: spy)
        h.start()
        XCTAssertEqual(spy.readCalls, 1)
        let claim = try XCTUnwrap(h.engine.calls(to: "/v1/handoff/claim").first?.body)
        XCTAssertEqual(claim["token"] as? String, TOKEN)
        XCTAssertEqual(claim["publishableKey"] as? String, PK)
        XCTAssertEqual(claim["platform"] as? String, "ios")
        XCTAssertNotNil(claim["openId"] as? String)
        XCTAssertNotNil(claim["at"])
        XCTAssertNil(claim["screenWidth"], "the claim carries no device fields")
        let match = try XCTUnwrap(h.engine.calls(to: "/v1/match").first?.body, "device matching runs first")
        XCTAssertEqual(match["openId"] as? String, claim["openId"] as? String, "one install, one openId")
        XCTAssertEqual(h.events.count, 1, "only the final result is emitted")
        let e = try XCTUnwrap(h.events.last)
        XCTAssertEqual(e.kind, .deferred)
        XCTAssertEqual(e.route, .clipboard)
        XCTAssertTrue(e.matched)
        XCTAssertEqual(e.url, "https://shop.example/promo/42?x=1")
        XCTAssertEqual(e.linkId, "lnk_42")
        XCTAssertEqual(e.id, claim["openId"] as? String)
        XCTAssertEqual(storage.getItem(StraitLinks.deferredFlag), "1")
        XCTAssertTrue(storage.getItem(StraitLinks.tapKey)?.contains(CLAIM_TAP) == true)
    }

    func testDeviceMatchFirstSkipsTheClipboard() throws {
        let spy = SpyPasteboard(probableURL: true, text: HANDOFF)
        let engine = FakeEngine([
            "/v1/match": ["matched": true, "longUrl": "https://shop.example/m", "linkId": "lnk_m", "ios": bothOn],
            "/v1/handoff/claim": claimed,
        ])
        let h = Harness(engine, pasteboard: spy)
        h.start()
        XCTAssertEqual(spy.touched, 0, "a device match never shows the paste prompt")
        XCTAssertTrue(engine.calls(to: "/v1/handoff/claim").isEmpty)
        XCTAssertEqual(h.events.count, 1)
        XCTAssertEqual(h.events.last?.route, .fingerprint)
        XCTAssertEqual(h.events.last?.matched, true)
    }

    func testDeviceMatchNetworkFailureLeavesTheClipboardAlone() throws {
        // No answer = the workspace's choice is unknown: nothing is read, and the
        // whole check runs again next launch with a fresh answer.
        for mode in [FakeEngine.Mode.offline, .status(429), .status(503)] {
            let spy = SpyPasteboard(probableURL: true, text: HANDOFF)
            let engine = FakeEngine(["/v1/match": noMatchPaste, "/v1/handoff/claim": claimed])
            engine.modes["/v1/match"] = mode
            let storage = MemoryStorage()
            let h = Harness(engine, storage: storage, pasteboard: spy)
            h.start()
            XCTAssertEqual(spy.touched, 0)
            XCTAssertTrue(engine.calls(to: "/v1/handoff/claim").isEmpty)
            XCTAssertEqual(h.events.last?.reason, "network")
            XCTAssertNil(storage.getItem(StraitLinks.deferredFlag), "checked again next launch")
        }
    }

    func testUnmatchedClaimKeepsTheDeviceMatchResultWithSameOpenId() throws {
        let spy = SpyPasteboard(probableURL: true, text: HANDOFF)
        let engine = FakeEngine([
            "/v1/handoff/claim": ["matched": false, "matchMethod": "none", "reason": "handoff_used"],
            "/v1/match": noMatchPaste,
        ])
        let h = Harness(engine, pasteboard: spy)
        h.start()
        let claim = try XCTUnwrap(engine.calls(to: "/v1/handoff/claim").first?.body)
        let match = try XCTUnwrap(engine.calls(to: "/v1/match").first?.body)
        XCTAssertEqual(claim["openId"] as? String, match["openId"] as? String)
        XCTAssertEqual(h.events.count, 1)
        XCTAssertEqual(h.events.last?.route, .fingerprint)
        XCTAssertEqual(h.events.last?.matched, false)
        XCTAssertEqual(h.events.last?.reason, "no_match")
    }

    func testNonHandoffTextSendsNoClaim() throws {
        for text in ["https://evil.example/h/\(TOKEN)", "https://links.test/promo", "hello", "http://links.test/h/\(TOKEN)"] {
            let spy = SpyPasteboard(probableURL: true, text: text)
            let engine = FakeEngine(["/v1/match": noMatchPaste])
            let h = Harness(engine, pasteboard: spy)
            h.start()
            XCTAssertEqual(spy.readCalls, 1, text)
            XCTAssertTrue(engine.calls(to: "/v1/handoff/claim").isEmpty, text)
            XCTAssertEqual(engine.calls(to: "/v1/match").count, 1, text)
            for c in engine.calls { XCTAssertFalse(String(describing: c.body ?? [:]).contains(text), "clipboard text never sent: \(text)") }
        }
    }

    func testClaimNetworkFailureRetriesNextLaunch() throws {
        for mode in [FakeEngine.Mode.offline, .status(429), .status(503)] {
            let spy = SpyPasteboard(probableURL: true, text: HANDOFF)
            let engine = FakeEngine(["/v1/match": noMatchPaste, "/v1/handoff/claim": claimed])
            engine.modes["/v1/handoff/claim"] = mode
            let storage = MemoryStorage()
            let h = Harness(engine, storage: storage, pasteboard: spy)
            h.start()
            XCTAssertEqual(h.events.last?.reason, "network")
            XCTAssertEqual(engine.calls(to: "/v1/match").count, 1, "device match ran first")
            XCTAssertNil(storage.getItem(StraitLinks.deferredFlag), "checked again next launch")
        }
    }

    func testClaimHandoffTextFromPasteButton() throws {
        let spy = SpyPasteboard()
        let engine = FakeEngine(["/v1/handoff/claim": claimed])
        let storage = MemoryStorage()
        storage.setItem(StraitLinks.deferredFlag, "1")
        let h = Harness(engine, storage: storage, pasteboard: spy)
        var got: LinkEvent?
        h.strait.claimHandoff(text: HANDOFF) { got = $0 }
        XCTAssertEqual(got?.matched, true)
        XCTAssertEqual(got?.route, .clipboard)
        XCTAssertEqual(engine.calls(to: "/v1/handoff/claim").count, 1)
        XCTAssertEqual(spy.touched, 0, "the paste button hands the text over; the SDK reads nothing itself")
    }

    func testClaimHandoffRejectsNonHandoffWithoutNetwork() throws {
        let engine = FakeEngine(["/v1/handoff/claim": claimed])
        let h = Harness(engine)
        var got: LinkEvent?
        h.strait.claimHandoff(text: "https://links.test/promo") { got = $0 }
        XCTAssertEqual(got?.matched, false)
        XCTAssertEqual(got?.reason, "not_handoff")
        XCTAssertTrue(engine.calls.isEmpty)
    }

    func testClaimHandoffUnmatchedReason() throws {
        let engine = FakeEngine(["/v1/handoff/claim": ["matched": false, "reason": "handoff_expired"]])
        let h = Harness(engine)
        var got: LinkEvent?
        h.strait.claimHandoff(text: HANDOFF) { got = $0 }
        XCTAssertEqual(got?.reason, "handoff_expired")
        XCTAssertEqual(got?.matched, false)
    }
}

/// Records which keys the SDK writes.
final class KeyRecordingStorage: StraitStorage {
    private let inner = MemoryStorage()
    private(set) var keys: Set<String> = []
    func getItem(_ key: String) -> String? { inner.getItem(key) }
    func setItem(_ key: String, _ value: String) { keys.insert(key); inner.setItem(key, value) }
}

/// Founder decision 10 Oct 2026 (Inbox T-6b + D18): the customer picks the iPhone
/// deferred-link method in the dashboard; the SDK reads it from the engine's
/// /v1/match reply on the once-per-install check, never from the app build.
final class DeferredMethodChoiceTests: XCTestCase {
    private func reply(matched: Bool, device: Bool, paste: Bool) -> [String: Any] {
        var r: [String: Any] = ["matched": matched, "matchMethod": matched ? "exact_ext" : "none",
                                "ios": ["deviceMatching": device, "pasteHandoff": paste]]
        if matched { r["longUrl"] = "https://shop.example/m"; r["linkId"] = "lnk_m" }
        if !device { r["reasons"] = ["device_matching_off"] }
        return r
    }

    private func run(_ match: [String: Any]) -> (Harness, SpyPasteboard) {
        let spy = SpyPasteboard(probableURL: true, text: HANDOFF)
        let h = Harness(FakeEngine(["/v1/match": match, "/v1/handoff/claim": claimed]), pasteboard: spy)
        h.start()
        XCTAssertEqual(h.engine.calls(to: "/v1/match").count, 1, "/v1/match always runs: it counts the install and carries the choice")
        XCTAssertEqual(h.events.count, 1, "one event per check")
        return (h, spy)
    }

    func testOffOff() {
        let (h, spy) = run(reply(matched: false, device: false, paste: false))
        XCTAssertEqual(spy.touched, 0)
        XCTAssertTrue(h.engine.calls(to: "/v1/handoff/claim").isEmpty)
        XCTAssertEqual(h.events.last?.route, .fingerprint)
        XCTAssertEqual(h.events.last?.matched, false)
        XCTAssertEqual(h.events.last?.reason, "no_match")
    }

    func testDeviceMatchingOnly() {
        let (hit, hitSpy) = run(reply(matched: true, device: true, paste: false))
        XCTAssertEqual(hitSpy.touched, 0)
        XCTAssertEqual(hit.events.last?.route, .fingerprint)
        XCTAssertEqual(hit.events.last?.matched, true)
        XCTAssertEqual(hit.events.last?.url, "https://shop.example/m")
        let (miss, missSpy) = run(reply(matched: false, device: true, paste: false))
        XCTAssertEqual(missSpy.touched, 0, "paste handoff off: no fallback")
        XCTAssertTrue(miss.engine.calls(to: "/v1/handoff/claim").isEmpty)
        XCTAssertEqual(miss.events.last?.reason, "no_match")
    }

    func testPasteHandoffOnly() throws {
        let (h, spy) = run(reply(matched: false, device: false, paste: true))
        XCTAssertEqual(spy.readCalls, 1)
        let claim = try XCTUnwrap(h.engine.calls(to: "/v1/handoff/claim").first?.body)
        let match = try XCTUnwrap(h.engine.calls(to: "/v1/match").first?.body)
        XCTAssertEqual(claim["openId"] as? String, match["openId"] as? String, "same openId: one install")
        XCTAssertEqual(h.events.last?.route, .clipboard)
        XCTAssertEqual(h.events.last?.matched, true)
    }

    func testBothDeviceMatchingFirstPasteAsFallback() {
        let (hit, hitSpy) = run(reply(matched: true, device: true, paste: true))
        XCTAssertEqual(hitSpy.touched, 0, "a device match never shows the paste prompt")
        XCTAssertTrue(hit.engine.calls(to: "/v1/handoff/claim").isEmpty)
        XCTAssertEqual(hit.events.last?.route, .fingerprint)
        let (miss, missSpy) = run(reply(matched: false, device: true, paste: true))
        XCTAssertEqual(missSpy.readCalls, 1)
        XCTAssertEqual(miss.engine.calls(to: "/v1/handoff/claim").count, 1)
        XCTAssertEqual(miss.events.last?.route, .clipboard)
        XCTAssertEqual(miss.events.last?.matched, true)
    }

    func testOlderEngineWithoutTheChoiceMeansNoPaste() {
        let (h, spy) = run(["matched": false, "matchMethod": "none"])
        XCTAssertEqual(spy.touched, 0)
        XCTAssertTrue(h.engine.calls(to: "/v1/handoff/claim").isEmpty)
    }

    func testTheDeprecatedAppFlagIsIgnored() {
        // An app built with clipboardBoost: true follows the dashboard (off here) ...
        let spy = SpyPasteboard(probableURL: true, text: HANDOFF)
        let engine = FakeEngine(["/v1/match": reply(matched: false, device: true, paste: false), "/v1/handoff/claim": claimed])
        let on = StraitLinks(StraitLinksConfig(
            publishableKey: PK, endpoint: ENDPOINT, storage: MemoryStorage(), transport: engine, device: { device },
            callbackQueue: nil, observeLifecycle: false, clipboardBoost: true, pasteboard: spy
        ))
        on.start(initialURL: nil)
        XCTAssertEqual(spy.touched, 0)
        // ... and one built with the default (false) still pastes when the dashboard says so.
        let spy2 = SpyPasteboard(probableURL: true, text: HANDOFF)
        let engine2 = FakeEngine(["/v1/match": reply(matched: false, device: false, paste: true), "/v1/handoff/claim": claimed])
        let off = StraitLinks(StraitLinksConfig(
            publishableKey: PK, endpoint: ENDPOINT, storage: MemoryStorage(), transport: engine2, device: { device },
            callbackQueue: nil, observeLifecycle: false, clipboardBoost: false, pasteboard: spy2
        ))
        off.start(initialURL: nil)
        XCTAssertEqual(spy2.readCalls, 1)
        XCTAssertEqual(engine2.calls(to: "/v1/handoff/claim").count, 1)
    }

    func testTheSameBuildFollowsTheDashboardAndStoresNothing() {
        // Same app build, two installs: the customer flipped the switch in between.
        let storage1 = KeyRecordingStorage(), storage2 = KeyRecordingStorage()
        let spy1 = SpyPasteboard(probableURL: true, text: HANDOFF), spy2 = SpyPasteboard(probableURL: true, text: HANDOFF)
        for (storage, spy, paste) in [(storage1, spy1, false), (storage2, spy2, true)] {
            let engine = FakeEngine(["/v1/match": reply(matched: false, device: true, paste: paste), "/v1/handoff/claim": claimed])
            StraitLinks(StraitLinksConfig(
                publishableKey: PK, endpoint: ENDPOINT, storage: storage, transport: engine, device: { device },
                callbackQueue: nil, observeLifecycle: false, pasteboard: spy
            )).start(initialURL: nil)
        }
        XCTAssertEqual(spy1.touched, 0)
        XCTAssertEqual(spy2.readCalls, 1)
        for s in [storage1, storage2] {
            XCTAssertTrue(s.keys.isSubset(of: [StraitLinks.deferredFlag, StraitLinks.tapKey, StraitLinks.queueKey]), "the choice is never stored: \(s.keys)")
        }
    }

    func testReplyPasteHandoff() {
        XCTAssertTrue(replyPasteHandoff(["ios": ["deviceMatching": false, "pasteHandoff": true]]))
        XCTAssertFalse(replyPasteHandoff(["ios": ["deviceMatching": true, "pasteHandoff": false]]))
        XCTAssertFalse(replyPasteHandoff(["ios": ["pasteHandoff": "true"]]))
        XCTAssertFalse(replyPasteHandoff(["pasteHandoff": true]))
        XCTAssertFalse(replyPasteHandoff([:]))
    }
}
