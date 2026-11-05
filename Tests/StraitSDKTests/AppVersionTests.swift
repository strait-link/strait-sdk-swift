import XCTest
@testable import StraitSDK

/// td2-23: every request that records an app open or install carries `appVersion` (the host app's
/// CFBundleShortVersionString) and `sdkVersion` (this SDK's), so support can answer "which app version?".
/// Not on /v1/lookup (opt-out path) or /v1/event; nothing at all while switched off. Engine rule: 1-64
/// printable ASCII, else dropped; the SDK trims and caps to 64 too.
final class AppVersionTests: XCTestCase {
    private static let token = "AbCdEfGhIjKlMnOpQrStUv"
    private let routes: [String: [String: Any]] = [
        "/v1/match": ["matched": false], "/v1/open": ["ok": true], "/v1/event": ["ok": true],
        "/v1/resolve": ["matched": true, "longUrl": "https://shop.example/p/42", "linkId": "lnk_42"],
    ]

    private func assertVersions(_ body: [String: Any]?, app: String? = "2.4.1", _ what: String, line: UInt = #line) {
        XCTAssertEqual(body?["appVersion"] as? String, app, what, line: line)
        XCTAssertEqual(body?["sdkVersion"] as? String, StraitLinks.sdkVersion, what, line: line)
    }

    private func assertNoVersions(_ body: [String: Any]?, _ what: String, line: UInt = #line) {
        XCTAssertNil(body?["appVersion"], what, line: line)
        XCTAssertNil(body?["sdkVersion"], what, line: line)
    }

    func testFirstLaunchMatchSendsBoth() {
        let h = Harness(FakeEngine(routes), appVersion: "2.4.1")
        h.start()
        assertVersions(h.engine.calls(to: "/v1/match").first?.body, "/v1/match (records the install)")
    }

    func testShortLinkResolveSendsBoth() {
        let h = Harness(FakeEngine(routes), storage: firstLaunchDone(), appVersion: "2.4.1")
        h.start()
        h.strait.handle(urlString: "https://links.test/sale")
        assertVersions(h.engine.calls(to: "/v1/resolve").first?.body, "/v1/resolve")
    }

    func testOpenReportSendsBoth() {
        let h = Harness(FakeEngine(routes), storage: firstLaunchDone(), appVersion: "2.4.1")
        h.start()
        h.strait.handle(urlString: "straitlink://shop.example/product/42")
        assertVersions(h.engine.calls(to: "/v1/open").first?.body, "/v1/open")
    }

    func testQueuedOpenRetrySendsBoth() {
        let engine = FakeEngine(routes)
        engine.modes["/v1/resolve"] = .offline
        let h = Harness(engine, storage: firstLaunchDone(), appVersion: "2.4.1")
        h.start()
        h.strait.handle(urlString: "https://links.test/sale") // offline: the open is saved for later
        engine.modes["/v1/resolve"] = nil
        h.strait.flushOpenReports()
        let retry = engine.calls(to: "/v1/open")
        XCTAssertEqual(retry.count, 1)
        assertVersions(retry.first?.body, "the saved /v1/open retry")
    }

    func testHandoffClaimSendsBoth() {
        let engine = FakeEngine([
            "/v1/match": ["matched": false, "ios": ["deviceMatching": true, "pasteHandoff": true]],
            "/v1/handoff/claim": ["matched": true, "longUrl": "https://shop.example/p/1", "linkId": "lnk_1"],
        ])
        let h = Harness(engine, pasteboard: SpyPasteboard(probableURL: true, text: "https://links.test/h/\(Self.token)"), appVersion: "2.4.1")
        h.start()
        assertVersions(engine.calls(to: "/v1/handoff/claim").first?.body, "/v1/handoff/claim")
    }

    func testEventSendsNeither() {
        let h = Harness(FakeEngine(routes), storage: firstLaunchDone(), appVersion: "2.4.1")
        h.start()
        h.strait.trackEvent("purchase", eventId: "ord_1")
        XCTAssertEqual(h.engine.calls(to: "/v1/event").count, 1)
        assertNoVersions(h.engine.calls(to: "/v1/event").first?.body, "/v1/event")
    }

    func testSwitchedOffSendsNeitherAndLookupHasNeither() {
        var r = routes
        r["/v1/lookup"] = ["matched": true, "longUrl": "https://shop.example/p/42"]
        let h = Harness(FakeEngine(r), appVersion: "2.4.1")
        h.strait.setEnabled(false)
        h.start()
        h.strait.handle(urlString: "https://links.test/sale")
        h.strait.handle(urlString: "straitlink://shop.example/product/42")
        h.strait.trackEvent("purchase")
        XCTAssertEqual(h.engine.calls.map(\.path), ["/v1/lookup"])
        assertNoVersions(h.engine.calls.first?.body, "/v1/lookup")
    }

    func testAppVersionIsTrimmedCappedOrDropped() {
        let long = String(repeating: "9", count: 80)
        let cases: [(String?, String?)] = [
            (" 3.0 \n", "3.0"), (long, String(repeating: "9", count: 64)), ("", nil), ("   ", nil),
            ("1.0-β", nil), ("1.0\u{7}", nil), (nil, nil),
        ]
        for (given, sent) in cases {
            let h = Harness(FakeEngine(routes), appVersion: given)
            h.start()
            let body = h.engine.calls(to: "/v1/match").first?.body
            XCTAssertEqual(body?["appVersion"] as? String, sent, String(describing: given))
            if sent == nil { XCTAssertFalse(body?.keys.contains("appVersion") ?? true, String(describing: given)) }
            XCTAssertEqual(body?["sdkVersion"] as? String, StraitLinks.sdkVersion)
        }
    }

    func testAppVersionComesFromTheBundleShortVersion() {
        XCTAssertEqual(appVersion(info: ["CFBundleShortVersionString": "5.1.2", "CFBundleVersion": "812"]), "5.1.2")
        XCTAssertNil(appVersion(info: ["CFBundleVersion": "812"]))
        XCTAssertNil(appVersion(info: ["CFBundleShortVersionString": 5]))
        XCTAssertNil(appVersion(info: nil))
    }

    /// The constant must match the newest released version in CHANGELOG.md (the release workflow
    /// checks the tag against it), so a release that forgets to bump it fails its tests.
    func testSdkVersionMatchesTheChangelog() throws {
        let changelog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CHANGELOG.md")
        let text = try String(contentsOf: changelog, encoding: .utf8)
        let newest = text.split(separator: "\n").lazy.compactMap { line -> String? in
            guard line.hasPrefix("## ") else { return nil }
            let v = line.dropFirst(3).split(separator: " ").first.map(String.init) ?? ""
            return v.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil ? v : nil
        }.first
        XCTAssertEqual(StraitLinks.sdkVersion, newest)
    }

    // MARK: Legacy Strait.resolveDeferredLink (also records an install on /v1/match)

    final class BodyRecorder: URLProtocol {
        static var bodies: [[String: Any]] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let s = request.httpBodyStream {
                s.open()
                var buf = [UInt8](repeating: 0, count: 4096)
                while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
                s.close()
            }
            Self.bodies.append((try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"matched":false,"matchMethod":"none"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    func testLegacyDeferredMatchSendsBoth() async {
        BodyRecorder.bodies = []
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [BodyRecorder.self]
        _ = await Strait.resolveDeferredLink(
            StraitConfig(publishableKey: "st_pub_test_x", endpoint: "https://acme.strait.link"),
            session: URLSession(configuration: c), storage: MemoryStorage()
        )
        XCTAssertEqual(BodyRecorder.bodies.count, 1)
        XCTAssertEqual(BodyRecorder.bodies.first?["sdkVersion"] as? String, StraitLinks.sdkVersion)
        XCTAssertEqual(BodyRecorder.bodies.first?["appVersion"] as? String, wireVersion(currentAppVersion()))
    }

    private func firstLaunchDone() -> MemoryStorage {
        let s = MemoryStorage()
        s.setItem(StraitLinks.deferredFlag, "1")
        return s
    }
}
