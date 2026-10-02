import XCTest
@testable import StraitSDK

/// shared-spec/conformance-vectors.json — the same cases every Strait SDK runs
/// (generated from sdk-react-native/src/core.ts). Do not edit the JSON here.
final class ConformanceTests: XCTestCase {
    var vectors: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "conformance-vectors", withExtension: "json"))
        vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func cases(_ key: String) throws -> [[String: Any]] {
        let list = try XCTUnwrap(vectors[key] as? [[String: Any]], key)
        XCTAssertFalse(list.isEmpty, key)
        return list
    }

    func testConstants() throws {
        let c = try XCTUnwrap(vectors["constants"] as? [String: Any])
        XCTAssertEqual(c["RESUME_WINDOW_MS"] as? Double, RESUME_WINDOW_MS)
        XCTAssertEqual(c["TRANSIENT_PAUSE_MS"] as? Double, TRANSIENT_PAUSE_MS)
    }

    func testBrowserScreenWidth() throws {
        for v in try cases("screenWidth") {
            let logical = try XCTUnwrap(v["logical"] as? Double)
            XCTAssertEqual(browserScreenWidth(logical), v["expected"] as? Int, "\(logical)")
        }
    }

    func testSplitUrl() throws {
        for v in try cases("splitUrl") {
            let input = try XCTUnwrap(v["input"] as? String)
            XCTAssertEqual(splitUrl(input), try splitFrom(v["expected"]), input)
        }
    }

    func testParseStraitLink() throws {
        for v in try cases("referrer") {
            let input = v["input"] as? String // null → nil
            XCTAssertEqual(parseStraitLink(input), v["expected"] as? String, String(describing: input))
        }
    }

    func testClassifyUrl() throws {
        for v in try cases("classify") {
            let raw = try XCTUnwrap(v["raw"] as? String)
            let hosts = try XCTUnwrap(v["linkHosts"] as? [String])
            var expected: ClassifiedUrl?
            if let e = v["expected"] as? [String: Any] {
                let route = try XCTUnwrap(LinkRoute(rawValue: try XCTUnwrap(e["route"] as? String)))
                if e["needsResolve"] as? Bool == true {
                    XCTAssertEqual(route, .appLink)
                    expected = .shortLink
                } else {
                    expected = .destination(
                        route: route,
                        url: try XCTUnwrap(e["url"] as? String),
                        path: try XCTUnwrap(e["path"] as? String),
                        params: try XCTUnwrap(e["params"] as? [String: String])
                    )
                }
            }
            XCTAssertEqual(classifyUrl(raw, linkHosts: hosts), expected, raw)
        }
    }

    func testNormalizeLinkHosts() throws {
        for v in try cases("linkHosts") {
            let endpoint = try XCTUnwrap(v["endpoint"] as? String)
            let hosts = try XCTUnwrap(v["linkHosts"] as? [String])
            XCTAssertEqual(normalizeLinkHosts(endpoint, hosts), v["expected"] as? [String], endpoint)
        }
    }

    func testAppStateTracker() throws {
        for v in try cases("appState") {
            let name = v["name"] as? String ?? "?"
            let steps = try XCTUnwrap(v["steps"] as? [[Any]], name)
            let tracker = AppStateTracker()
            var got: [String] = []
            for step in steps {
                switch step.first as? String {
                case "state":
                    let state = try XCTUnwrap(AppLifecycleState(rawValue: try XCTUnwrap(step[1] as? String)), name)
                    tracker.onState(state, now: try XCTUnwrap(step[2] as? Double, name))
                case "url":
                    got.append(tracker.classify(try XCTUnwrap(step[1] as? Double, name)).rawValue)
                default:
                    XCTFail("unknown step in \(name)")
                }
            }
            XCTAssertEqual(got, v["expected"] as? [String], name)
        }
    }

    private func splitFrom(_ any: Any?) throws -> SplitUrl? {
        guard let e = any as? [String: Any] else { return nil }
        return SplitUrl(
            scheme: try XCTUnwrap(e["scheme"] as? String),
            host: try XCTUnwrap(e["host"] as? String),
            path: try XCTUnwrap(e["path"] as? String),
            params: try XCTUnwrap(e["params"] as? [String: String])
        )
    }
}
