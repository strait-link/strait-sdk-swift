import XCTest
@testable import StraitSDK

/// doctor-vectors.json (contract B23, ADR 0002): every iOS case gives the same ids, severities, titles and fixes
/// as the React Native reference (0.9.3), Android and Flutter, which carry the same file. Android cases (assetlinks,
/// certificates) don't apply to this SDK.
final class DoctorVectorsTests: XCTestCase {
    func testEveryIOSVector() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "doctor-vectors", withExtension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let vectors = try XCTUnwrap(root["vectors"] as? [[String: Any]]).filter { ($0["input"] as? [String: Any])?["platform"] as? String == "ios" }
        XCTAssertGreaterThanOrEqual(vectors.count, 10)
        for v in vectors {
            let name = v["name"] as? String ?? "?"
            let input = try XCTUnwrap(v["input"] as? [String: Any])
            let f = input["file"] as? [String: Any]
            let file = f.map { DoctorFile(status: $0["status"] as? Int, body: $0["body"] as? String) }
            let got = doctorFindings(publishableKey: input["publishableKey"] as? String ?? "", endpoint: input["endpoint"] as? String ?? "",
                                     platform: "ios", appId: input["appId"] as? String, file: file)
            let want = try XCTUnwrap(v["findings"] as? [[String: String]]).map {
                DoctorFinding(id: $0["id"]!, severity: $0["severity"]!, title: $0["title"]!, fix: $0["fix"]!)
            }
            XCTAssertEqual(got, want, name)
            XCTAssertEqual(!got.contains { $0.severity == "error" }, v["ok"] as? Bool, name)
        }
    }
}
