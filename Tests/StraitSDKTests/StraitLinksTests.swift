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
        XCTAssertEqual(body["url"] as? String, "https://shop.example/p/42?color=red")
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
