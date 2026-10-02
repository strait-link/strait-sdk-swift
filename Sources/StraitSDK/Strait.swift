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
        let body: [String: Any] = [
            "publishableKey": config.publishableKey,
            "platform": "ios",
            "screenWidth": device.screenWidth,
            "pixelRatio": device.pixelRatio,
            "language": device.language,
            "timezone": device.timezone,
        ]
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

struct DeviceFields {
    let screenWidth: Int
    let pixelRatio: Double
    let language: String
    let timezone: String
}

func collectDevice() -> DeviceFields {
    #if canImport(UIKit)
    let screen = UIScreen.main
    let width = Int(screen.bounds.width.rounded())
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
