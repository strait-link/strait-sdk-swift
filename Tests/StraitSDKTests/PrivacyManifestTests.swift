import Foundation
import XCTest

/// The shipped privacy manifest must declare what the SDK can collect, or apps' App Store privacy reports are wrong.
final class PrivacyManifestTests: XCTestCase {
    private func collectedTypes() throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/StraitSDK/PrivacyInfo.xcprivacy")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        return try XCTUnwrap(plist?["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
    }

    /// setUserId (B27): the app's own user id goes with events, so it is linked to the user, never used for tracking.
    func testDeclaresUserIdLinkedNotTrackingForAppFunctionalityAndAnalytics() throws {
        let entry = try XCTUnwrap(
            collectedTypes().first { $0["NSPrivacyCollectedDataType"] as? String == "NSPrivacyCollectedDataTypeUserID" },
            "PrivacyInfo.xcprivacy has no NSPrivacyCollectedDataTypeUserID entry")
        XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
        XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
        XCTAssertEqual(entry["NSPrivacyCollectedDataTypePurposes"] as? [String], [
            "NSPrivacyCollectedDataTypePurposeAppFunctionality",
            "NSPrivacyCollectedDataTypePurposeAnalytics",
        ])
    }
}
