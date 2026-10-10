import Foundation

// App Clip handoff (beta; the iPhone side of Strait is beta).
//
// An App Clip launched from one of your Strait links receives the exact link
// (`NSUserActivity.webpageURL`). It saves that link in an App Group the App
// Clip and the full app share. When the person then installs the full app,
// its first launch takes the link and passes it to `start(initialURL:)`: an
// exact deferred deep link with no device matching and no clipboard.
//
// Apple shares an App Group container between an App Clip and its full app
// (both need the same "App Groups" capability, e.g. group.com.yourco.app), and
// the container's contents carry over when the full app replaces the App Clip.
//
//   // App Clip
//   .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
//       if let url = activity.webpageURL, let store = StraitAppClip.storage(appGroup: "group.com.yourco.app") {
//           StraitAppClip.saveInvocation(url, storage: store)
//       }
//   }
//
//   // Full app, at launch, before `start`
//   let clipURL = StraitAppClip.storage(appGroup: "group.com.yourco.app")
//       .flatMap { StraitAppClip.takeInvocation(storage: $0) }
//   strait.start(initialURL: clipURL)   // clipURL nil = the normal deferred check

public enum StraitAppClip {
    /// Where the App Clip's invocation link is kept: `{"url":…,"at":<ms>}`.
    public static let invocationKey = "strait.appClipInvocation"
    /// How long a saved invocation stays usable (the attribution window, 7 days).
    public static let maxAgeMs: Double = ATTRIBUTION_WINDOW_MS

    /// The App Group's shared defaults as Strait storage, or nil when the
    /// group isn't in the app's entitlements.
    public static func storage(appGroup: String) -> StraitStorage? {
        guard !appGroup.isEmpty, let defaults = UserDefaults(suiteName: appGroup) else { return nil }
        return UserDefaultsStorage(defaults: defaults)
    }

    /// App Clip side: remember the link that launched it. Only https links
    /// are kept; a later invocation replaces an earlier one.
    @discardableResult
    public static func saveInvocation(_ url: URL, storage: StraitStorage, now: Double = Date().timeIntervalSince1970 * 1000) -> Bool {
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return false }
        let record: [String: Any] = ["url": url.absoluteString, "at": Int64(now)]
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              let text = String(data: data, encoding: .utf8) else { return false }
        storage.setItem(invocationKey, text)
        return true
    }

    /// Full app side: the saved invocation link, once. It is cleared whether
    /// or not it is still fresh, so it can never be handled twice.
    public static func takeInvocation(storage: StraitStorage, now: Double = Date().timeIntervalSince1970 * 1000,
                                      maxAgeMs: Double = StraitAppClip.maxAgeMs) -> URL? {
        guard let text = storage.getItem(invocationKey), !text.isEmpty else { return nil }
        storage.setItem(invocationKey, "")
        guard let data = text.data(using: .utf8),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = record["url"] as? String, let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let at = (record["at"] as? NSNumber)?.doubleValue,
              at <= now + 60_000, now - at <= maxAgeMs else { return nil }
        return url
    }
}
