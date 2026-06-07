import XCTest
@testable import StraitSDK

/// Golden-vector parity with the server + every other SDK. If Swift drifts,
/// deferred match breaks silently — this is the cross-language contract.
final class SignatureTests: XCTestCase {
    struct Vectors: Decodable {
        struct H32: Decodable { let input: String; let expected: String }
        struct Sig: Decodable {
            struct Input: Decodable {
                let screenWidth: Double; let pixelRatio: Double
                let language: String; let ip: String; let timezone: String
            }
            struct Expected: Decodable {
                let coreRaw: String; let extRaw: String
                let coreHash: String; let extHash: String
            }
            let name: String; let input: Input; let expected: Expected
        }
        let h32: [H32]
        let signatures: [Sig]
    }

    func loadVectors() throws -> Vectors {
        let url = Bundle.module.url(forResource: "test-vectors", withExtension: "json")!
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    func testH32GoldenVectors() throws {
        for v in try loadVectors().h32 {
            XCTAssertEqual(h32(v.input), v.expected, "h32(\(v.input))")
        }
    }

    func testSignatureGoldenVectors() throws {
        for v in try loadVectors().signatures {
            let sig = computeSignature(SignatureInputs(
                screenWidth: v.input.screenWidth,
                pixelRatio: v.input.pixelRatio,
                language: v.input.language,
                ip: v.input.ip,
                timezone: v.input.timezone
            ))
            XCTAssertEqual(sig.coreRaw, v.expected.coreRaw, v.name)
            XCTAssertEqual(sig.extRaw, v.expected.extRaw, v.name)
            XCTAssertEqual(sig.coreHash, v.expected.coreHash, v.name)
            XCTAssertEqual(sig.extHash, v.expected.extHash, v.name)
        }
    }

    func testNumStrParity() {
        XCTAssertEqual(numStr(3), "3")
        XCTAssertEqual(numStr(2.625), "2.625")
        XCTAssertEqual(numStr(1176), "1176")
    }
}
