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
        XCTAssertEqual(c["OPEN_QUEUE_MAX"] as? Int, OPEN_QUEUE_MAX)
        XCTAssertEqual(c["OPEN_QUEUE_MAX_AGE_MS"] as? Double, OPEN_QUEUE_MAX_AGE_MS)
        XCTAssertEqual(c["ATTRIBUTION_WINDOW_MS"] as? Double, ATTRIBUTION_WINDOW_MS)
    }

    func testEventClickId() throws {
        for v in try cases("eventClickId") {
            let name = try XCTUnwrap(v["name"] as? String)
            let now = try XCTUnwrap(v["now"] as? Double, name)
            XCTAssertEqual(
                eventClickId(v["stored"] as? String, now: now, explicit: v["explicit"] as? String),
                v["expected"] as? String, name
            )
        }
    }

    func testReplyClickId() throws {
        for v in try cases("replyClickId") {
            let name = try XCTUnwrap(v["name"] as? String)
            XCTAssertEqual(
                replyClickId(v["reply"] is NSNull ? nil : v["reply"], fallback: v["fallback"] as? String),
                v["expected"] as? String, name
            )
        }
    }

    func testReportUrl() throws {
        for v in try cases("reportUrl") {
            let input = try XCTUnwrap(v["input"] as? String)
            XCTAssertEqual(reportUrl(input), v["expected"] as? String, input)
        }
    }

    func testStaleTap() throws {
        for v in try cases("staleTap") {
            let name = try XCTUnwrap(v["name"] as? String)
            let now = try XCTUnwrap(v["now"] as? Double, name)
            XCTAssertEqual(staleTap(v["stored"] as? String, now: now), try XCTUnwrap(v["expected"] as? Bool, name), name)
        }
    }

    func testBrowserScreenWidth() throws {
        for v in try cases("screenWidth") {
            let logical = try XCTUnwrap(v["logical"] as? Double)
            XCTAssertEqual(browserScreenWidth(logical), v["expected"] as? Int, "\(logical)")
        }
    }

    func testPortraitScreenWidth() throws {
        for v in try cases("portraitScreenWidth") {
            let w = try XCTUnwrap(v["width"] as? Double), h = try XCTUnwrap(v["height"] as? Double)
            XCTAssertEqual(portraitScreenWidth(w, h), v["expected"] as? Int, "\(w)x\(h)")
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

    func testParseStraitClick() throws {
        for v in try cases("referrerClick") {
            let input = v["input"] as? String // null → nil
            XCTAssertEqual(parseStraitClick(input), v["expected"] as? String, String(describing: input))
        }
    }

    func testTakeClickId() throws {
        for v in try cases("takeClickId") {
            let input = try XCTUnwrap(v["input"] as? String)
            let e = try XCTUnwrap(v["expected"] as? [String: Any], input)
            XCTAssertNotNil(e["clickId"], "clickId present (possibly null): \(input)")
            let expected = ClickIdSplit(url: try XCTUnwrap(e["url"] as? String), clickId: e["clickId"] as? String)
            XCTAssertEqual(takeClickId(input), expected, input)
        }
    }

    func testPruneOpenQueue() throws {
        struct Entry { let openId: String; let at: Double }
        for v in try cases("openQueue") {
            let name = v["name"] as? String ?? "?"
            let now = try XCTUnwrap(v["now"] as? Double, name)
            let queue = try XCTUnwrap(v["queue"] as? [[String: Any]], name).map {
                Entry(openId: try XCTUnwrap($0["openId"] as? String, name), at: try XCTUnwrap($0["at"] as? Double, name))
            }
            XCTAssertEqual(pruneOpenQueue(queue, now: now) { $0.at }.map(\.openId), v["expected"] as? [String], name)
        }
    }

    func testShouldRetryReport() throws {
        for v in try cases("retry") {
            let status = v["status"] as? Int // null → nil (no answer)
            XCTAssertEqual(shouldRetryReport(status), try XCTUnwrap(v["expected"] as? Bool), String(describing: status))
        }
    }

    func testNewOpenId() {
        let id = newOpenId(1_800_000_000_000)
        XCTAssertNotNil(id.range(of: "^o_[a-z0-9]+_[a-z0-9]{12}$", options: .regularExpression), id)
        XCTAssertTrue(id.hasPrefix("o_\(String(1_800_000_000_000, radix: 36))_"), id)
        XCTAssertEqual(newOpenId(36, random: { 0 }), "o_10_aaaaaaaaaaaa")
        XCTAssertEqual(newOpenId(0, random: { 0.9999999 }), "o_0_999999999999")
        XCTAssertNotEqual(newOpenId(1), newOpenId(1))
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
                    XCTAssertNotNil(e["clickId"], "clickId present (possibly null): \(raw)")
                    expected = .destination(
                        route: route,
                        url: try XCTUnwrap(e["url"] as? String),
                        path: try XCTUnwrap(e["path"] as? String),
                        params: try XCTUnwrap(e["params"] as? [String: String]),
                        clickId: e["clickId"] as? String // null → nil
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
