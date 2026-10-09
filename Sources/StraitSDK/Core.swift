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
    /// A deferred link claimed from the clipboard boost's handoff link (B19).
    case clipboard
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

/// The `screenWidth` device field (B17): the screen's SHORTER side, as a browser
/// reports it. Safari's `screen.width` at the tap is the portrait width whatever
/// the orientation, so an app first launched in landscape (844×390) still reports 390.
public func portraitScreenWidth(_ logicalWidth: Double, _ logicalHeight: Double) -> Int {
    browserScreenWidth(min(logicalWidth, logicalHeight))
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
    referrerParam(referrer, "strait_link")
}

/// The tap id (`strait_click`) inside a Play Install Referrer string, or nil.
/// Joins the install to the exact tap that sent the user to the store.
public func parseStraitClick(_ referrer: String?) -> String? {
    guard let v = referrerParam(referrer, "strait_click"), isClickId(v) else { return nil }
    return v
}

private func referrerParam(_ referrer: String?, _ key: String) -> String? {
    guard let referrer = referrer, !referrer.isEmpty else { return nil }
    for pair in referrer.components(separatedBy: "&") {
        guard let eq = pair.range(of: "="), pair[..<eq.lowerBound] == key else { continue }
        let v = decode(String(pair[eq.upperBound...]))
        return v.isEmpty ? nil : v
    }
    return nil
}

/// A tap id as Strait issues it (uuid); anything else is ignored.
private let clickIdPattern = try! NSRegularExpression(
    pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\z", options: [.caseInsensitive]
)

private func isClickId(_ v: String) -> Bool {
    clickIdPattern.firstMatch(in: v, range: NSRange(location: 0, length: (v as NSString).length)) != nil
}

/// A URL with its `strait_click` tap id taken out (`takeClickId`).
public struct ClickIdSplit: Equatable {
    public let url: String
    /// The tap id, lower-cased; nil when absent or malformed.
    public let clickId: String?
}

/// Remove every `strait_click` parameter from a URL's query, keeping the rest
/// of the URL byte-for-byte (fragment included). Returns the cleaned URL and
/// the tap id (nil when absent or malformed). The app never sees the tap id.
public func takeClickId(_ raw: String) -> ClickIdSplit {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let hash = s.firstIndex(of: "#")
    let beforeHash = hash.map { String(s[..<$0]) } ?? s
    let frag = hash.map { String(s[$0...]) } ?? ""
    guard let q = beforeHash.firstIndex(of: "?") else { return ClickIdSplit(url: s, clickId: nil) }
    var clickId: String?
    let kept = beforeHash[beforeHash.index(after: q)...].components(separatedBy: "&").filter { pair in
        let eq = pair.range(of: "=")
        let key = eq.map { String(pair[..<$0.lowerBound]) } ?? pair
        if decode(key) != "strait_click" { return true }
        let v = decode(eq.map { String(pair[$0.upperBound...]) } ?? "")
        if isClickId(v) { clickId = v.lowercased() }
        return false
    }
    let query = kept.joined(separator: "&")
    return ClickIdSplit(url: String(beforeHash[..<q]) + (query.isEmpty ? "" : "?" + query) + frag, clickId: clickId)
}

/// What a URL handed to the app means.
public enum ClassifiedUrl: Equatable {
    /// https on a Strait link host → a short link; ask /v1/resolve (route `app_link`).
    case shortLink
    /// The URL already carries the destination. `clickId` is the tap id from a
    /// Strait hand-off (removed from url/params), else nil.
    case destination(route: LinkRoute, url: String, path: String, params: [String: String], clickId: String?)
}

/// The deep link inside an old Firebase Dynamic Links long link (contract B22):
/// `https://<x>.page.link/?link=<url>&apn=…` → `<url>`. Only on a `*.page.link`
/// host, only at the root path, only when `link` is an absolute http(s) URL with
/// a host. Anything else → nil (a page.link short link is resolved by the engine).
public func pageLinkLongLink(_ p: SplitUrl) -> String? {
    guard p.host.hasSuffix(".page.link"), p.path == "/" || p.path.isEmpty else { return nil }
    guard let link = p.params["link"], !link.isEmpty, let inner = splitUrl(link),
          inner.scheme == "https" || inner.scheme == "http", !inner.host.isEmpty else { return nil }
    return link.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// - https on a Strait link host → `.shortLink`. Except an FDL long link on a
///   `*.page.link` link host (B22): its `link=` value IS the destination, read on
///   the device with no network call.
/// - other https (a verified link on the customer's own site) → it IS the destination.
/// - yourapp://host/path (browser hand-off) → destination https://host/path.
/// A `strait_click` tap id is removed from the destination and returned apart.
/// Returns nil for anything that isn't a URL.
public func classifyUrl(_ raw: String, linkHosts: [String]) -> ClassifiedUrl? {
    guard let p0 = splitUrl(raw) else { return nil }
    let isWeb = p0.scheme == "https" || p0.scheme == "http"
    if isWeb && linkHosts.map({ $0.lowercased() }).contains(p0.host) {
        if let long = pageLinkLongLink(p0),
           case let .destination(_, url, path, params, clickId)? = classifyUrl(long, linkHosts: []) {
            return .destination(route: .appLink, url: url, path: path, params: params, clickId: clickId)
        }
        return .shortLink
    }
    let taken = takeClickId(raw)
    let clean = taken.url
    guard let p = splitUrl(clean) else { return nil }
    let url = isWeb ? clean : schemePrefix.stringByReplacingMatches(
        in: clean, range: NSRange(location: 0, length: (clean as NSString).length), withTemplate: "https://"
    )
    return .destination(route: isWeb ? .appLink : .customScheme, url: url, path: p.path, params: p.params, clickId: taken.clickId)
}

/// Open reports waiting to be sent are kept at most this long (ms)…
public let OPEN_QUEUE_MAX_AGE_MS: Double = 7 * 24 * 60 * 60 * 1000
/// …and at most this many (oldest dropped first).
public let OPEN_QUEUE_MAX = 100

/// Prune a pending-report queue: drop reports older than `OPEN_QUEUE_MAX_AGE_MS`
/// (by their `at`), then keep the newest `OPEN_QUEUE_MAX`. Order is kept.
public func pruneOpenQueue<T>(_ queue: [T], now: Double, at: (T) -> Double) -> [T] {
    Array(queue.filter { now - at($0) <= OPEN_QUEUE_MAX_AGE_MS }.suffix(OPEN_QUEUE_MAX))
}

/// Conversion events carry the tap id of the most recent attributed link open
/// for this long, ms (contract B15).
public let ATTRIBUTION_WINDOW_MS: Double = 7 * 24 * 60 * 60 * 1000

/// Storage value for the remembered tap (key `strait.lastTap`):
/// `{"clickId":…,"at":<epoch ms>}`.
public func rememberTap(_ clickId: String, at: Double) -> String {
    let obj: [String: Any] = ["clickId": clickId.lowercased(), "at": Int64(at)]
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
          let s = String(data: data, encoding: .utf8) else { return "" }
    return s
}

/// The `clickId` a conversion event sends (contract B15): a non-empty
/// `explicit` wins; otherwise the remembered tap (`stored`, see `rememberTap`)
/// when it is a valid tap id opened at most `ATTRIBUTION_WINDOW_MS` before
/// `now` (and not after it). Anything unreadable means no tap.
public func eventClickId(_ stored: String?, now: Double, explicit: String? = nil) -> String? {
    if let explicit = explicit, !explicit.isEmpty { return explicit }
    guard let stored = stored, !stored.isEmpty, let data = stored.data(using: .utf8),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let clickId = obj["clickId"] as? String, isClickId(clickId),
          let atNum = obj["at"] as? NSNumber, CFGetTypeID(atNum) != CFBooleanGetTypeID()
    else { return nil }
    let at = atNum.doubleValue
    guard at.isFinite else { return nil }
    let age = now - at
    return age >= 0 && age <= ATTRIBUTION_WINDOW_MS ? clickId.lowercased() : nil
}

/// True when the remembered tap (`stored`, see `rememberTap`) is set but can no
/// longer be used: unreadable, malformed, or opened more than
/// `ATTRIBUTION_WINDOW_MS` before `now` (or after it). The SDK then deletes it
/// instead of keeping it on the device (contract B18).
public func staleTap(_ stored: String?, now: Double) -> Bool {
    guard let stored = stored, !stored.isEmpty else { return false }
    return eventClickId(stored, now: now) == nil
}

/// The URL an SDK reports to the engine (`/v1/open`, `/v1/resolve`) or saves in
/// the open queue (contract B18): the query string and fragment are removed,
/// except the first `utm_source` pair, kept byte for byte, because the engine
/// reads it for channel attribution. The engine keeps nothing else from the
/// query: it stores host + path only. The query is what sits before any '#',
/// between the first and second '?'. Works on UTF-8 bytes (the delimiters are
/// ASCII), so the result matches every other SDK exactly.
public func reportUrl(_ url: String) -> String {
    var bytes = Array(url.utf8)
    if let hash = bytes.firstIndex(of: UInt8(ascii: "#")) { bytes = Array(bytes[..<hash]) }
    guard let q = bytes.firstIndex(of: UInt8(ascii: "?")) else { return String(decoding: bytes, as: UTF8.self) }
    let base = Array(bytes[..<q])
    let rest = bytes[(q + 1)...]
    let query = rest.split(separator: UInt8(ascii: "?"), maxSplits: 1, omittingEmptySubsequences: false).first ?? []
    let key = Array("utm_source".utf8)
    for pair in query.split(separator: UInt8(ascii: "&"), omittingEmptySubsequences: false) {
        let name = pair.firstIndex(of: UInt8(ascii: "=")).map { pair[pair.startIndex..<$0] } ?? pair
        if Array(name) == key {
            return String(decoding: base + [UInt8(ascii: "?")] + Array(pair), as: UTF8.self)
        }
    }
    return String(decoding: base, as: UTF8.self)
}

/// The tap id to remember after an attributed open the engine answered
/// (contract B16): the reply's `clickId` when it is a valid tap id
/// (lower-cased); else `fallback` when valid (a tap id the SDK already knew,
/// e.g. the Play referrer's — so an older engine that returns none keeps B15);
/// else nil, which forgets the remembered tap (the newer touch wins).
public func replyClickId(_ reply: Any?, fallback: String? = nil) -> String? {
    if let r = reply as? String, isClickId(r) { return r.lowercased() }
    if let f = fallback, isClickId(f) { return f.lowercased() }
    return nil
}

/// The referral code in a matched deferred reply (`/v1/match`,
/// `/v1/handoff/claim`), or nil (contract B21, proposal). Only a valid code
/// (1-64 letters, digits, - or _) counts, kept exactly as sent; anything
/// else, or an engine that sends no `referralCode`, gives nil.
public func replyReferralCode(_ reply: Any?) -> String? {
    guard let r = reply as? String, (1...64).contains(r.utf8.count),
          r.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F })
    else { return nil }
    return r
}

/// Whether a failed report should be kept for retry: no answer (nil), 429 or 5xx.
public func shouldRetryReport(_ status: Int?) -> Bool {
    guard let status = status else { return true }
    return status == 429 || status >= 500
}

/// A unique id for one link open (the engine de-duplicates retries by it):
/// `o_<base36 ms>_<12 × [a-z0-9]>`.
public func newOpenId(_ now: Double, random: () -> Double = { Double.random(in: 0..<1) }) -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    var r = ""
    for _ in 0..<12 { r.append(alphabet[min(35, Int(random() * 36))]) }
    return "o_\(String(Int64(now), radix: 36))_\(r)"
}

/// A clipboard-boost handoff token as the tap page mints it: 128 random bits, base64url (B19).
private let handoffToken = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{22}$")
private let handoffLink = try! NSRegularExpression(
    pattern: "^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#\\s]+)/h/([^/?#\\s]*)/?(?:[?#]\\S*)?$"
)

/// The handoff token inside text read from the clipboard (contract B19), or
/// nil. Only a Strait handoff link counts: `https://<link host>/h/<token>`,
/// where the host is one of this app's link hosts (`normalizeLinkHosts`), the
/// path is exactly `/h/<22 base64url chars>` (one trailing slash allowed), and
/// the whole text (trimmed) is that one URL. A query or fragment after it is
/// ignored. Scheme and host compare case-insensitively; path and token don't.
public func parseHandoffUrl(_ text: String?, linkHosts: [String]) -> String? {
    guard let text = text else { return nil }
    let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty, s.utf16.count <= 2048 else { return nil }
    let ns = s as NSString
    guard let m = handoffLink.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
    guard ns.substring(with: m.range(at: 1)).lowercased() == "https" else { return nil }
    let host = ns.substring(with: m.range(at: 2)).lowercased()
    guard linkHosts.contains(where: { $0.lowercased() == host }) else { return nil }
    let token = ns.substring(with: m.range(at: 3))
    let tn = token as NSString
    return handoffToken.firstMatch(in: token, range: NSRange(location: 0, length: tn.length)) != nil ? token : nil
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
