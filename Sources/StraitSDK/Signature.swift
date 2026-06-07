import Foundation

/// Strait deferred-match signature — Swift port of shared-spec/RECIPE.md.
/// MUST be byte-identical to the JS reference (server + JS/Dart SDKs). The
/// golden vectors are the contract.
///
/// Cross-language trap: JS `h32` wraps at 32 bits signed (`h |= 0`). Swift `Int`
/// is 64-bit, so we use `Int32` with the overflow operators (&*, &-, &+) which
/// wrap exactly like JS's 32-bit bitwise math.

public struct Signature: Equatable {
    public let coreRaw: String
    public let extRaw: String
    public let coreHash: String
    public let extHash: String
}

public struct SignatureInputs {
    public let screenWidth: Double
    public let pixelRatio: Double
    public let language: String
    public let ip: String
    public let timezone: String

    public init(screenWidth: Double, pixelRatio: Double, language: String, ip: String, timezone: String) {
        self.screenWidth = screenWidth
        self.pixelRatio = pixelRatio
        self.language = language
        self.ip = ip
        self.timezone = timezone
    }
}

private let regionMap: [String: String] = [
    "Asia/Kolkata": "IN", "Asia/Karachi": "PK", "Asia/Dhaka": "BD",
    "America/New_York": "US", "America/Chicago": "US", "America/Denver": "US",
    "America/Los_Angeles": "US", "Europe/London": "GB", "Europe/Paris": "EU",
    "Europe/Berlin": "EU", "Asia/Singapore": "SG", "Asia/Dubai": "AE",
    "Australia/Sydney": "AU",
]

/// Deterministic 32-bit string hash (Java hashCode → abs → hex), matching JS.
public func h32(_ s: String) -> String {
    var h: Int32 = 0
    for u in s.utf16 {                       // iterate UTF-16 code units like JS
        h = (h &* 31) &+ Int32(truncatingIfNeeded: Int(u))  // (h<<5)-h == h*31, wrapping
    }
    // abs then lowercase hex, no leading zeros; Int(-2^31) handled via magnitude.
    let magnitude = UInt32(bitPattern: h < 0 ? (0 &- h) : h)
    return String(magnitude, radix: 16)
}

/// Mirror JS `String(Number)`: whole numbers print with no decimal point.
public func numStr(_ n: Double) -> String {
    if n == n.rounded() && abs(n) < 1e15 {
        return String(Int(n))
    }
    return String(n)
}

public func regionFromTimezone(_ timezone: String) -> String {
    let tz = timezone == "Asia/Calcutta" ? "Asia/Kolkata" : timezone
    return regionMap[tz] ?? "XX"
}

public func computeSignature(_ input: SignatureInputs) -> Signature {
    let screenWidth = Int(input.screenWidth.rounded())
    let rawLang = input.language.isEmpty ? "en" : input.language
    let language = String(rawLang.prefix(2)).lowercased()

    let coreFields = ["universal", numStr(Double(screenWidth)), numStr(input.pixelRatio), language, input.ip]
    let coreRaw = coreFields.joined(separator: "|")

    let physWidth = Int((Double(screenWidth) * input.pixelRatio / 8.0).rounded()) * 8
    let region = regionFromTimezone(input.timezone)
    let extRaw = (coreFields + [numStr(Double(physWidth)), region]).joined(separator: "|")

    return Signature(coreRaw: coreRaw, extRaw: extRaw, coreHash: h32(coreRaw), extHash: h32(extRaw))
}
