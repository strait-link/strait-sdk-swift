import Foundation
import StraitSDK

/// Where the reference app gets its settings, strongest first:
/// 1. the launch environment (XCUITest / `xcodebuild test` pass STRAIT_ENDPOINT,
///    STRAIT_PK; Xcode scheme env vars work too),
/// 2. values typed on the Settings screen (kept in UserDefaults),
/// 3. the build (Info.plist keys filled from Config/*.xcconfig by set-team.sh).
/// Only the PUBLISHABLE key (st_pub_…) ever belongs here; it ships inside apps.
enum ReferenceConfig {
    private static let defaults = UserDefaults.standard
    private static let env = ProcessInfo.processInfo.environment

    static func info(_ key: String) -> String {
        let v = (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
        // An unset build setting can arrive as the literal "$(NAME)".
        return v.hasPrefix("$(") ? "" : v.trimmingCharacters(in: .whitespaces)
    }

    private static func value(env key: String, saved: String, info infoKey: String) -> String {
        if let v = env[key], !v.isEmpty {
            defaults.set(v, forKey: saved) // a cold launch by a link later still has it
            return v
        }
        if let v = defaults.string(forKey: saved), !v.isEmpty { return v }
        return info(infoKey)
    }

    /// The workspace link host the app claims (applinks:), e.g. strait-dev.strait.link.
    static var linkHost: String { info("StraitLinkHost") }

    static var endpoint: String {
        let host = linkHost
        return value(env: "STRAIT_ENDPOINT", saved: "ref.endpoint", info: "StraitEndpoint").nonEmpty
            ?? (host.isEmpty ? "" : "https://\(host)")
    }

    static var publishableKey: String { value(env: "STRAIT_PK", saved: "ref.pk", info: "StraitPublishableKey") }

    static func save(endpoint: String, publishableKey: String) {
        defaults.set(endpoint.trimmingCharacters(in: .whitespaces), forKey: "ref.endpoint")
        defaults.set(publishableKey.trimmingCharacters(in: .whitespaces), forKey: "ref.pk")
    }

    static var appGroup: String { info("StraitAppGroup") }
    /// True only in the App Clip build (STRAIT_APP_CLIP=1 scripts/generate.sh).
    static var appClipEnabled: Bool { info("StraitAppClip") == "YES" }
    static var urlScheme: String { info("StraitURLScheme").nonEmpty ?? "straitref" }
    static var bundleId: String { Bundle.main.bundleIdentifier ?? "" }
    /// TEAMID. when signed (Xcode fills $(AppIdentifierPrefix)); empty when unsigned.
    static var appIdPrefix: String { info("StraitAppIdPrefix") }
    /// The App ID the AASA must list for Universal Links to open this app.
    static var appId: String { appIdPrefix.isEmpty ? "" : "\(appIdPrefix)\(bundleId)" }

    /// Testing aid: STRAIT_RESET=1 forgets the once-per-install deferred check,
    /// so the next start runs it again (like a fresh install, minus the App Store).
    static func resetIfAsked() {
        guard env["STRAIT_RESET"] == "1" else { return }
        resetFirstLaunch()
    }

    static func resetFirstLaunch() {
        for key in [StraitLinks.deferredFlag, StraitLinks.queueKey, StraitLinks.tapKey] { defaults.removeObject(forKey: key) }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
