import Foundation

/// Deferred-match result returned by `resolveDeferredLink`.
public struct MatchResult: Decodable, Equatable {
    public let matched: Bool
    public let longUrl: String?
    public let linkId: String?
    public let matchMethod: String

    public static let none = MatchResult(matched: false, longUrl: nil, linkId: nil, matchMethod: "none")
}

public struct StraitConfig {
    /// Workspace publishable key (`bk_pub_live_…` / `bk_pub_test_…`) from
    /// Dashboard → Get started. Safe to ship in apps; never use your secret
    /// key (`bk_live_…`) here.
    public let publishableKey: String
    public let endpoint: String
    public init(publishableKey: String, endpoint: String) {
        self.publishableKey = publishableKey
        self.endpoint = endpoint
    }
}

public enum Strait {
    /// Call once on first launch. Asks Strait whether this device recently
    /// clicked a link, and returns the deferred destination. Never throws —
    /// returns `.none` on any error. The server adds the observed IP.
    public static func resolveDeferredLink(
        _ config: StraitConfig,
        session: URLSession = .shared
    ) async -> MatchResult {
        let device = collectDevice()
        let base = config.endpoint.hasSuffix("/") ? String(config.endpoint.dropLast()) : config.endpoint
        guard let url = URL(string: "\(base)/v1/match") else { return .none }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = device.json
        body["publishableKey"] = config.publishableKey
        body["platform"] = "ios"
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .none
            }
            return (try? JSONDecoder().decode(MatchResult.self, from: data)) ?? .none
        } catch {
            return .none
        }
    }
}

/// Coarse device fields sent for the deferred match (the server adds the IP).
public struct DeviceFields: Equatable {
    public let screenWidth: Int
    public let pixelRatio: Double
    public let language: String
    public let timezone: String

    public init(screenWidth: Int, pixelRatio: Double, language: String, timezone: String) {
        self.screenWidth = screenWidth
        self.pixelRatio = pixelRatio
        self.language = language
        self.timezone = timezone
    }

    var json: [String: Any] {
        ["screenWidth": screenWidth, "pixelRatio": pixelRatio, "language": language, "timezone": timezone]
    }
}

/// This device's fields. `screenWidth` is `browserScreenWidth` of the logical
/// width, so it equals what Safari reports at the tap (B2).
public func collectDevice() -> DeviceFields {
    #if canImport(UIKit) && !os(watchOS)
    let screen = UIScreen.main
    let width = browserScreenWidth(Double(screen.bounds.width))
    let scale = Double(screen.scale)
    #else
    let width = 0
    let scale = 1.0
    #endif
    let lang = Locale.preferredLanguages.first ?? "en"
    let tz = TimeZone.current.identifier
    return DeviceFields(screenWidth: width, pixelRatio: scale, language: lang, timezone: tz)
}

#if canImport(UIKit)
import UIKit
#endif
