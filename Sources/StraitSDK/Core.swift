import Foundation

/// Pure, platform-free link logic — a 1:1 port of `sdk-react-native/src/core.ts`.
/// `Tests/StraitSDKTests/conformance-vectors.json` is the cross-language
/// contract (see shared-spec/SDK-CONTRACT.md).

/// How the app received a link.
public enum LinkRoute: String, Equatable, Decodable {
    case appLink = "app_link"
    case customScheme = "custom_scheme"
    case installReferrer = "install_referrer"
    case fingerprint
}

/// What the app was doing when the link arrived.
public enum AppStateAtLink: String, Equatable, Decodable {
    case closed, background, foreground
}

/// App lifecycle state, as `AppStateTracker` sees it.
public enum AppLifecycleState: String, Equatable, Decodable {
    case active, background, inactive
}

/// Screen width as a browser reports it (`screen.width`). Chrome rounds
/// fractional logical widths UP (1080 px at 2.625 = 411.43 → 412). Matching
/// needs the app and the browser at the tap to agree.
public func browserScreenWidth(_ logicalWidth: Double) -> Int {
    Int((logicalWidth - 0.001).rounded(.up))
}

public struct SplitUrl: Equatable, Decodable {
    public let scheme: String
    public let host: String
    public let path: String
    public let params: [String: String]
}

private let urlPattern = try! NSRegularExpression(
    pattern: "^([a-z][a-z0-9+.-]*)://([^/?#]*)([^?#]*)(?:\\?([^#]*))?",
    options: [.caseInsensitive]
)
private let schemePrefix = try! NSRegularExpression(pattern: "^[a-z][a-z0-9+.-]*://", options: [.caseInsensitive])

/// Split a URL without relying on platform URL classes (`URLComponents`
/// treats '+' and malformed input differently from the other SDKs). Scheme
/// and host are lower-cased; '+' and %-escapes in the query are decoded;
/// fragment dropped.
public func splitUrl(_ u: String) -> SplitUrl? {
    let s = u.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
    guard let m = urlPattern.firstMatch(in: s as String, range: NSRange(location: 0, length: s.length)) else {
        return nil
    }
    func group(_ i: Int) -> String? {
        let r = m.range(at: i)
        return r.location == NSNotFound ? nil : s.substring(with: r)
    }
    var params: [String: String] = [:]
    for pair in (group(4) ?? "").components(separatedBy: "&") where !pair.isEmpty {
        if let eq = pair.range(of: "=") {
            params[decode(String(pair[..<eq.lowerBound]))] = decode(String(pair[eq.upperBound...]))
        } else {
            params[decode(pair)] = ""
        }
    }
    let path = group(3) ?? ""
    return SplitUrl(
        scheme: (group(1) ?? "").lowercased(),
        host: (group(2) ?? "").lowercased(),
        path: path.isEmpty ? "/" : path,
        params: params
    )
}

/// JS `decodeURIComponent(s.replace(/\+/g, ' '))`, returning `s` unchanged
/// when it has a malformed escape (as the JS `catch` does).
func decode(_ s: String) -> String {
    s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
}

private let bareHost = try! NSRegularExpression(pattern: "^[a-z0-9.-]+(:\\d+)?$", options: [.caseInsensitive])

/// The hosts that serve Strait short links: the endpoint's host plus each of
/// `linkHosts`, given as URLs (`https://go.brand.com`) or bare hosts
/// (`go.brand.com`, `localhost:3000`). Lower-cased, de-duplicated in order;
/// blanks and anything with a path or spaces are ignored.
public func normalizeLinkHosts(_ endpoint: String, _ linkHosts: [String] = []) -> [String] {
    var out: [String] = []
    for h in [endpoint] + linkHosts {
        let t = h.trimmingCharacters(in: .whitespacesAndNewlines)
        let isBare = bareHost.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil
        let host = splitUrl(h)?.host ?? (isBare ? t.lowercased() : nil)
        if let host = host, !host.isEmpty, !out.contains(host) { out.append(host) }
    }
    return out
}

/// The `strait_link` id inside a Play Install Referrer string, or nil.
public func parseStraitLink(_ referrer: String?) -> String? {
    guard let referrer = referrer, !referrer.isEmpty else { return nil }
    for pair in referrer.components(separatedBy: "&") {
        guard let eq = pair.range(of: "="), pair[..<eq.lowerBound] == "strait_link" else { continue }
        let v = decode(String(pair[eq.upperBound...]))
        return v.isEmpty ? nil : v
    }
    return nil
}

/// What a URL handed to the app means.
public enum ClassifiedUrl: Equatable {
    /// https on a Strait link host → a short link; ask /v1/resolve (route `app_link`).
    case shortLink
    /// The URL already carries the destination.
    case destination(route: LinkRoute, url: String, path: String, params: [String: String])
}

/// - https on a Strait link host → `.shortLink`.
/// - other https (a verified link on the customer's own site) → it IS the destination.
/// - yourapp://host/path (browser hand-off) → destination https://host/path.
/// Returns nil for anything that isn't a URL.
public func classifyUrl(_ raw: String, linkHosts: [String]) -> ClassifiedUrl? {
    guard let p = splitUrl(raw) else { return nil }
    let isWeb = p.scheme == "https" || p.scheme == "http"
    if isWeb && linkHosts.map({ $0.lowercased() }).contains(p.host) {
        return .shortLink
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = isWeb ? trimmed : schemePrefix.stringByReplacingMatches(
        in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length), withTemplate: "https://"
    )
    return .destination(route: isWeb ? .appLink : .customScheme, url: url, path: p.path, params: p.params)
}

/// A link arriving this soon after the app came back to the front came "from background".
public let RESUME_WINDOW_MS: Double = 2000
/// Pauses shorter than this are the OS delivering the link, not the user leaving.
public let TRANSIENT_PAUSE_MS: Double = 1000

/// Tracks app lifecycle to label a link delivered while the app is running.
/// The OS can wrap link delivery in a brief pause/resume, and the link can
/// arrive before or after the resume: a pause under `TRANSIENT_PAUSE_MS` is
/// that delivery (app was on screen); a longer one means the user had left.
/// Times are milliseconds.
public final class AppStateTracker {
    private var state: AppLifecycleState = .active
    private var backgroundAt = -Double.infinity
    private var resumeAt = -Double.infinity
    private var backgroundFor: Double = 0

    public init() {}

    public func onState(_ s: AppLifecycleState, now: Double) {
        if s != .active && state == .active { backgroundAt = now }
        if s == .active && state != .active {
            resumeAt = now
            backgroundFor = now - backgroundAt
        }
        state = s
    }

    /// Label for a link delivered (while running) at `now`.
    public func classify(_ now: Double) -> AppStateAtLink {
        var away: Double?
        if state != .active { away = now - backgroundAt }
        else if now - resumeAt <= RESUME_WINDOW_MS { away = backgroundFor }
        if let away = away, away >= TRANSIENT_PAUSE_MS { return .background }
        return .foreground
    }
}
