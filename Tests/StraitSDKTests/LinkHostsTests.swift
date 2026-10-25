@testable import StraitSDK
import XCTest

/// normalizeLinkHosts scans ASCII instead of using NSRegularExpression (no ICU load in init, H3).
/// It must give what the regex version gave, so the old code is kept here as the oracle.
final class LinkHostsTests: XCTestCase {
    private func oracle(_ endpoint: String, _ linkHosts: [String]) -> [String] {
        let bare = try! NSRegularExpression(pattern: "^[a-z0-9.-]+(:\\d+)?$", options: [.caseInsensitive])
        var out: [String] = []
        for h in [endpoint] + linkHosts {
            let t = h.trimmingCharacters(in: .whitespacesAndNewlines)
            let isBare = bare.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil
            let host = splitUrl(h)?.host ?? (isBare ? t.lowercased() : nil)
            if let host = host, !host.isEmpty, !out.contains(host) { out.append(host) }
        }
        return out
    }

    func testMatchesTheRegexVersion() {
        let inputs = [
            "https://Acme.strait.link", "https://acme.strait.link/", " https://acme.strait.link/x?y#z ", "HTTPS://A.B",
            "go.brand.com", "GO.Brand.com", "localhost:3000", "localhost:", "localhost:3000x", ":3000", "",
            "   ", "\n", "go brand.com", "go.brand.com/path", "https://", "https:///path", "ftp+x.y-z://h.com:8443/p",
            "1http://a.com", "http:/a.com", "http//a.com", "a://b", "x-y.z", "_a.com", "a_b.com", "https://h?q", "https://h#f",
            "https://user@h.com", "https://h.com:99", "été.com", "https://été.com", "a.com::1", "https://a.com\n",
        ]
        for i in inputs {
            XCTAssertEqual(normalizeLinkHosts(i, []), oracle(i, []), "endpoint \(i.debugDescription)")
            XCTAssertEqual(normalizeLinkHosts("https://e.strait.link", [i, i.uppercased()]), oracle("https://e.strait.link", [i, i.uppercased()]), "linkHosts \(i.debugDescription)")
        }
    }

    /// The one intended difference: ICU's \d took any Unicode digit; the JS reference, Kotlin and Dart take 0-9 only.
    func testPortDigitsAreAsciiLikeTheOtherSdks() {
        XCTAssertEqual(normalizeLinkHosts("a.com:\u{0661}\u{0662}", []), [])
        XCTAssertEqual(normalizeLinkHosts("a.com:12", []), ["a.com:12"])
    }
}
