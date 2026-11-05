import XCTest
@testable import StraitSDK

/// F5: the legacy `Strait.resolveDeferredLink` honours the opt-out switch (docs/adr/0001-opt-out.md).
/// It reads `strait.enabled` from the same storage as `StraitLinks` (default: UserDefaults.standard).
final class LegacyOptOutTests: XCTestCase {
    /// Records every request and answers a matched deferred link.
    final class Recorder: URLProtocol {
        static var paths: [String] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.paths.append(request.url?.path ?? "")
            let data = #"{"matched":true,"linkId":"lnk_42","matchMethod":"exact_ext"}"#.data(using: .utf8)!
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [Recorder.self]
        return URLSession(configuration: c)
    }
    private let config = StraitConfig(publishableKey: "st_pub_test_x", endpoint: "https://acme.strait.link")

    override func setUp() { Recorder.paths = [] }

    func testSwitchedOffThroughStraitLinksSendsNothingAndMatchesNothing() async {
        let s = MemoryStorage()
        Harness(FakeEngine(), storage: s).strait.setEnabled(false)
        let r = await Strait.resolveDeferredLink(config, session: session, storage: s)
        XCTAssertEqual(r, .none)
        XCTAssertEqual(Recorder.paths, [])
    }

    func testOnAsksTheEngineAsBefore() async {
        let r = await Strait.resolveDeferredLink(config, session: session, storage: MemoryStorage())
        XCTAssertTrue(r.matched)
        XCTAssertEqual(Recorder.paths, ["/v1/match"])
    }
}
