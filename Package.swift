// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "StraitSDK",
    platforms: [.iOS(.v13), .macOS(.v11)],
    products: [
        .library(name: "StraitSDK", targets: ["StraitSDK"]),
    ],
    targets: [
        .target(name: "StraitSDK", resources: [.copy("PrivacyInfo.xcprivacy")]),
        .testTarget(
            name: "StraitSDKTests",
            dependencies: ["StraitSDK"],
            resources: [.copy("test-vectors.json"), .copy("conformance-vectors.json")]
        ),
    ]
)
