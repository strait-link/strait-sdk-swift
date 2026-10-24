import XCTest
@testable import StraitSDK

/// `doctorFindings` against every row of shared-spec ADR 0002 (contract B23), then `doctor()`
/// over a fake transport. The live check runs only with STRAIT_DOCTOR_LIVE=1 (never in CI).

private let PUB = "st_pub_live_abc123"
private let HOST = "acme.strait.link"
private let ENDPOINT = "https://\(HOST)"

private func aasa(_ details: [[String: Any]]) -> DoctorFile {
    let data = try! JSONSerialization.data(withJSONObject: ["applinks": ["apps": [], "details": details]])
    return DoctorFile(status: 200, body: String(data: data, encoding: .utf8))
}

private let listed = aasa([["appIDs": ["TEAM123.com.acme.shop"], "appID": "TEAM123.com.acme.shop"]])

private func check(key: String = PUB, endpoint: String = ENDPOINT, app: String? = "com.acme.shop",
                 file: DoctorFile? = listed) -> [DoctorFinding] {
    doctorFindings(publishableKey: key, endpoint: endpoint, platform: "ios", appId: app, file: file)
}

final class DoctorFindingsTests: XCTestCase {
    func testKeyOk() {
        XCTAssertEqual(check().first, DoctorFinding(id: "key.ok", severity: "ok", title: "Publishable key is set", fix: ""))
    }

    func testSecretKeys() {
        let secret = DoctorFinding(id: "key.secret", severity: "error",
            title: "This is a secret key, not the publishable key",
            fix: "Use the publishable key (st_pub_…) from Dashboard → Get started, and revoke this secret key in Dashboard → Settings → Secret keys: it has been inside your app.")
        XCTAssertEqual(check(key: "st_live_xyz").first, secret)
        XCTAssertEqual(check(key: "st_test_xyz").first, secret)
    }

    func testInvalidKey() {
        let invalid = DoctorFinding(id: "key.invalid", severity: "error", title: "Not a publishable key",
            fix: "Copy the publishable key (st_pub_…) from Dashboard → Get started.")
        XCTAssertEqual(check(key: "").first, invalid)
        XCTAssertEqual(check(key: "bk_pub_test_1").first, invalid)
    }

    func testInvalidEndpointStopsHostChecks() {
        let bad = DoctorFinding(id: "endpoint.invalid", severity: "error", title: "The endpoint isn't an https link domain",
            fix: "Set endpoint to your link domain from Dashboard → Get started, e.g. https://<handle>.strait.link.")
        for e in ["http://\(HOST)", "acme.strait.link", "", "https://"] {
            XCTAssertEqual(check(endpoint: e, file: nil).map(\.id), ["key.ok", "endpoint.invalid"], e)
            XCTAssertEqual(check(endpoint: e, file: nil)[1], bad, e)
        }
    }

    func testUnreachable() {
        XCTAssertEqual(check(file: DoctorFile(status: nil, body: nil))[1], DoctorFinding(id: "host.unreachable", severity: "error",
            title: "Can't reach \(HOST)",
            fix: "Check that endpoint is your link domain (Dashboard → Get started) and that this device is online."))
    }

    func testFileMissing() {
        let missing = DoctorFinding(id: "host.file_missing", severity: "error",
            title: "\(HOST) doesn't serve apple-app-site-association",
            fix: "Use your Strait link domain as endpoint (Dashboard → Get started); Strait serves this file there.")
        XCTAssertEqual(check(file: DoctorFile(status: 404, body: "{}"))[1], missing)
        XCTAssertEqual(check(file: DoctorFile(status: 200, body: "<html>not json</html>"))[1], missing)
        XCTAssertEqual(check(file: DoctorFile(status: 200, body: "{\"webcredentials\":{}}"))[1], missing)
        XCTAssertEqual(check(file: DoctorFile(status: 200, body: nil))[1], missing)
    }

    func testNoApp() {
        let none = DoctorFinding(id: "app.none", severity: "error", title: "No iOS app is set up for \(HOST)",
            fix: "Add your app in Dashboard → Apps & stores.")
        XCTAssertEqual(check(file: aasa([]))[1], none)
        XCTAssertEqual(check(file: DoctorFile(status: 200, body: "{\"applinks\":{}}"))[1], none)
    }

    func testAppMissing() {
        let file = aasa([["appIDs": ["TEAM123.com.acme.shop", "TEAM123.com.acme.beta"]], ["appID": "OTHER99.com.acme.old"]])
        XCTAssertEqual(check(app: "com.acme.other", file: file)[1], DoctorFinding(id: "app.missing", severity: "error",
            title: "\(HOST) doesn't list com.acme.other",
            fix: "Add com.acme.other in Dashboard → Apps & stores (listed now: TEAM123.com.acme.shop, TEAM123.com.acme.beta, OTHER99.com.acme.old)."))
    }

    func testAppListedShowsFullAppID() {
        XCTAssertEqual(check(), [
            DoctorFinding(id: "key.ok", severity: "ok", title: "Publishable key is set", fix: ""),
            DoctorFinding(id: "app.listed", severity: "ok", title: "\(HOST) lists TEAM123.com.acme.shop", fix: ""),
        ])
        // Legacy single `appID` counts too; the match is "ends with .{bundle}", so a longer bundle doesn't.
        XCTAssertEqual(check(file: aasa([["appID": "TEAM9.com.acme.shop"]]))[1].title, "\(HOST) lists TEAM9.com.acme.shop")
        XCTAssertEqual(check(app: "com.acme.shop.beta")[1].id, "app.missing")
        XCTAssertEqual(check(app: "TEAM123.com.acme.shop")[1].id, "app.missing")
    }

    func testAppUnknown() {
        let unknown = DoctorFinding(id: "app.unknown", severity: "warn", title: "\(HOST) lists TEAM123.com.acme.shop",
            fix: "Make sure your app is one of these.")
        XCTAssertEqual(check(app: nil)[1], unknown)
        XCTAssertEqual(check(app: "")[1], unknown)
    }

    func testEndpointTrailingSlashAndPathUseHost() {
        XCTAssertEqual(check(endpoint: "https://\(HOST)/")[1].title, "\(HOST) lists TEAM123.com.acme.shop")
    }
}

/// Answers one canned response and records the request.
private final class OneShot: StraitTransport {
    let result: Result<StraitHTTPResponse, Error>?
    var urls: [String] = []
    init(_ result: Result<StraitHTTPResponse, Error>?) { self.result = result }
    func send(_ request: URLRequest, completion: @escaping (Result<StraitHTTPResponse, Error>) -> Void) {
        urls.append(request.url!.absoluteString)
        XCTAssertEqual(request.httpMethod ?? "GET", "GET")
        if let r = result { completion(r) }
    }
}

final class DoctorTests: XCTestCase {
    private func client(_ t: StraitTransport, key: String = PUB, endpoint: String = ENDPOINT + "/") -> StraitLinks {
        StraitLinks(StraitLinksConfig(publishableKey: key, endpoint: endpoint, storage: MemoryStorage(),
                                      transport: t, callbackQueue: nil, observeLifecycle: false))
    }

    func testOneGetOfTheAASA() {
        let t = OneShot(.success(StraitHTTPResponse(status: 200, data: listed.body!.data(using: .utf8)!)))
        var report: DoctorReport?
        client(t).doctor(bundleId: "com.acme.shop") { report = $0 }
        XCTAssertEqual(t.urls, ["https://\(HOST)/.well-known/apple-app-site-association"])
        XCTAssertEqual(report?.ok, true)
        XCTAssertEqual(report?.findings.map(\.id), ["key.ok", "app.listed"])
    }

    func testNetworkFailureIsAFindingNotAThrow() {
        let t = OneShot(.failure(URLError(.notConnectedToInternet)))
        var report: DoctorReport?
        client(t, key: "st_live_oops").doctor(bundleId: "com.acme.shop") { report = $0 }
        XCTAssertEqual(report?.ok, false)
        XCTAssertEqual(report?.findings.map(\.id), ["key.secret", "host.unreachable"])
    }

    func testInvalidEndpointSkipsTheRequest() {
        let t = OneShot(nil)
        var report: DoctorReport?
        client(t, endpoint: "http://\(HOST)").doctor(bundleId: nil) { report = $0 }
        XCTAssertEqual(t.urls, [])
        XCTAssertEqual(report?.findings.map(\.id), ["key.ok", "endpoint.invalid"])
    }

    func testWarnAloneKeepsOk() {
        let t = OneShot(.success(StraitHTTPResponse(status: 200, data: listed.body!.data(using: .utf8)!)))
        var report: DoctorReport?
        client(t).doctor(bundleId: nil) { report = $0 }
        XCTAssertEqual(report, DoctorReport(ok: true, findings: check(app: nil)))
    }

    func testCompletesOnTheCallbackQueue() {
        let t = OneShot(.failure(URLError(.timedOut)))
        let strait = StraitLinks(StraitLinksConfig(publishableKey: PUB, endpoint: ENDPOINT, storage: MemoryStorage(),
                                                   transport: t, callbackQueue: .main, observeLifecycle: false))
        let done = expectation(description: "doctor")
        strait.doctor(bundleId: "com.acme.shop") { _ in
            XCTAssertTrue(Thread.isMainThread)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    /// The real thing, opt-in: STRAIT_DOCTOR_LIVE=1 swift test --filter DoctorTests/testLive
    func testLive() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["STRAIT_DOCTOR_LIVE"] == "1" else { throw XCTSkip("set STRAIT_DOCTOR_LIVE=1 to call strait-dev.strait.link") }
        let endpoint = env["STRAIT_DOCTOR_ENDPOINT"] ?? "https://strait-dev.strait.link"
        let strait = StraitLinks(StraitLinksConfig(publishableKey: "st_pub_live_placeholder", endpoint: endpoint,
                                                   storage: MemoryStorage(), callbackQueue: nil, observeLifecycle: false))
        for bundle in ["in.straitlink.reference", "com.example.unlisted"] {
            let done = expectation(description: bundle)
            strait.doctor(bundleId: bundle) { report in
                print("doctor(bundleId: \"\(bundle)\") against \(endpoint) -> ok=\(report.ok)")
                report.findings.forEach { print("  \($0.severity) \($0.id): \($0.title)\($0.fix.isEmpty ? "" : " | fix: \($0.fix)")") }
                if bundle == "in.straitlink.reference" {
                    XCTAssertEqual(report.findings.map(\.id), ["key.ok", "app.listed"])
                    XCTAssertEqual(report.findings.last?.title, "strait-dev.strait.link lists C3L6B5HJU7.in.straitlink.reference")
                } else {
                    XCTAssertEqual(report.findings.map(\.id), ["key.ok", "app.missing"])
                }
                done.fulfill()
            }
            wait(for: [done], timeout: 20)
        }
    }
}
