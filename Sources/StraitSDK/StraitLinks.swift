import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Public types

/// direct = the app was opened by a link; deferred = link tapped before install.
public enum LinkKind: String, Equatable {
    case direct, deferred
}

/// One event type for every link the app receives (SDK-CONTRACT B9).
public struct LinkEvent: Equatable {
    public let id: String
    public let kind: LinkKind
    /// appLink: verified https link opened the app directly ·
    /// customScheme: a browser handed off to the app (yourapp://…) ·
    /// fingerprint: how a deferred link was found on iOS.
    public let route: LinkRoute
    /// What the app was doing when the link arrived.
    public let appState: AppStateAtLink
    public let matched: Bool
    /// Why it didn't match: not_found, expired, password_protected, no_match, network, invalid_url, …
    public let reason: String?
    /// The URL the OS gave the app (direct links).
    public let rawUrl: String?
    /// The destination to navigate to.
    public let url: String?
    public let path: String?
    public let params: [String: String]?
    public let linkId: String?
    /// Time spent resolving, ms.
    public let ms: Double
    /// When the link arrived, ms since 1970.
    public let at: Double
}

/// Fired the moment a link arrives, before it's resolved (resolving can take a
/// second or more on slow networks): show an "Opening link…" state until the
/// matching `LinkEvent` (same `id`) arrives.
public struct LinkStart: Equatable {
    public let id: String
    public let kind: LinkKind
    public let appState: AppStateAtLink
    public let rawUrl: String?
    public let at: Double
}

/// Persistent key/value storage for the once-per-install flag.
public protocol StraitStorage {
    func getItem(_ key: String) -> String?
    func setItem(_ key: String, _ value: String)
}

/// The default storage.
public struct UserDefaultsStorage: StraitStorage {
    public let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func getItem(_ key: String) -> String? { defaults.string(forKey: key) }
    public func setItem(_ key: String, _ value: String) { defaults.set(value, forKey: key) }
}

/// In-memory storage (tests, or apps that persist the flag themselves).
public final class MemoryStorage: StraitStorage {
    private let lock = NSLock()
    private var data: [String: String] = [:]
    public init() {}
    public func getItem(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return data[key]
    }
    public func setItem(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        data[key] = value
    }
}

public struct StraitHTTPResponse {
    public let status: Int
    public let data: Data
    public init(status: Int, data: Data) {
        self.status = status
        self.data = data
    }
}

/// HTTP behind one method so tests (and custom stacks) can swap it.
public protocol StraitTransport {
    func send(_ request: URLRequest, completion: @escaping (Result<StraitHTTPResponse, Error>) -> Void)
}

/// The default transport.
public struct URLSessionTransport: StraitTransport {
    public let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func send(_ request: URLRequest, completion: @escaping (Result<StraitHTTPResponse, Error>) -> Void) {
        session.dataTask(with: request) { data, response, error in
            if let error = error { return completion(.failure(error)) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            completion(.success(StraitHTTPResponse(status: status, data: data ?? Data())))
        }.resume()
    }
}

/// Returned by `onLink` / `onLinkStart`; call `cancel()` to unsubscribe.
public final class StraitSubscription {
    private var onCancel: (() -> Void)?
    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    public func cancel() {
        onCancel?()
        onCancel = nil
    }
}

public struct StraitLinksConfig {
    /// Workspace publishable key (`bk_pub_live_…`), Dashboard → Get started.
    public var publishableKey: String
    /// Your Strait link host, e.g. https://go.yourbrand.com
    public var endpoint: String
    /// Extra hosts that serve your short links (custom domains), as
    /// `https://go.brand.com` or `go.brand.com`.
    public var linkHosts: [String]
    /// Persists `strait.deferredChecked`. Default: `UserDefaults.standard`.
    public var storage: StraitStorage
    public var transport: StraitTransport
    /// Clock in ms since 1970.
    public var now: () -> Double
    /// Device fields for the deferred match / fingerprint report.
    public var device: () -> DeviceFields
    /// Sent as `platform` to the engine.
    public var platform: String
    /// Where callbacks run. Default main; nil = whatever thread finished the work.
    public var callbackQueue: DispatchQueue?
    /// `start` observes UIApplication notifications for app-state labelling
    /// (UIKit platforms only). Turn off to feed `onAppState` yourself.
    public var observeLifecycle: Bool

    public init(
        publishableKey: String,
        endpoint: String,
        linkHosts: [String] = [],
        storage: StraitStorage = UserDefaultsStorage(),
        transport: StraitTransport = URLSessionTransport(),
        now: @escaping () -> Double = { Date().timeIntervalSince1970 * 1000 },
        device: @escaping () -> DeviceFields = { Thread.isMainThread ? collectDevice() : DispatchQueue.main.sync(execute: collectDevice) },
        platform: String = "ios",
        callbackQueue: DispatchQueue? = .main,
        observeLifecycle: Bool = true
    ) {
        self.publishableKey = publishableKey
        self.endpoint = endpoint
        self.linkHosts = linkHosts
        self.storage = storage
        self.transport = transport
        self.now = now
        self.device = device
        self.platform = platform
        self.callbackQueue = callbackQueue
        self.observeLifecycle = observeLifecycle
    }
}

enum StraitLinksError: Error {
    case badEndpoint, badBody
}

// MARK: - Client

/// The Strait deep-link client: direct links (Universal Links, custom scheme),
/// deferred links (once per install) and analytics. A port of the React
/// Native `createStrait`; never throws to the app.
public final class StraitLinks {
    public static let deferredFlag = "strait.deferredChecked"

    private let config: StraitLinksConfig
    private let base: String
    private let linkHosts: [String]
    private let tracker = AppStateTracker()
    private let lock = NSLock()
    private var events: [LinkEvent] = []
    private var listeners: [(Int, (LinkEvent) -> Void)] = []
    private var startListeners: [(Int, (LinkStart) -> Void)] = []
    private var nextToken = 0
    private var seq = 0
    private var observers: [NSObjectProtocol] = []

    public init(_ config: StraitLinksConfig) {
        self.config = config
        var base = config.endpoint
        while base.hasSuffix("/") { base.removeLast() }
        self.base = base
        self.linkHosts = normalizeLinkHosts(base, config.linkHosts)
    }

    deinit { removeObservers() }

    // MARK: Lifecycle

    /// Handles the launch link (pass the URL that launched the app from closed,
    /// e.g. from `connectionOptions` in `scene(_:willConnectTo:options:)`), then
    /// runs the deferred check once per install — skipped (but marked done)
    /// when the launch itself was a link.
    public func start(initialURL: URL? = nil, completion: (() -> Void)? = nil) {
        if config.observeLifecycle { observeAppLifecycle() }
        let deferredStep = { [self] in
            if config.storage.getItem(Self.deferredFlag) != "1" {
                config.storage.setItem(Self.deferredFlag, "1")
                // Opened by a link on first launch = the user's intent right now.
                if initialURL == nil {
                    runDeferred { [self] _ in deliver { completion?() } }
                    return
                }
            }
            deliver { completion?() }
        }
        if let initial = initialURL {
            handleUrl(initial.absoluteString, appState: .closed) { _ in deferredStep() }
        } else {
            deferredStep()
        }
    }

    /// A link delivered while the app is running: Universal Link
    /// (`scene(_:continue:)` / `application(_:continue:restorationHandler:)`),
    /// custom scheme (`scene(_:openURLContexts:)` / `application(_:open:options:)`)
    /// or SwiftUI `onOpenURL`.
    public func handle(url: URL) {
        handle(urlString: url.absoluteString)
    }

    public func handle(urlString: String) {
        let appState = withLock { tracker.classify(config.now()) }
        handleUrl(urlString, appState: appState, completion: nil)
    }

    /// Universal Link via `NSUserActivity`. Returns false when the activity
    /// isn't a web link (nothing to handle).
    @discardableResult
    public func handle(userActivity: NSUserActivity) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else { return false }
        handle(url: url)
        return true
    }

    /// Feed app lifecycle changes (if `observeLifecycle` is off). `at` in ms; default now.
    public func onAppState(_ state: AppLifecycleState, at: Double? = nil) {
        let now = at ?? config.now()
        withLock { tracker.onState(state, now: now) }
    }

    /// Observe UIApplication notifications (called by `start` unless
    /// `observeLifecycle` is false). No-op without UIKit.
    public func observeAppLifecycle() {
        #if canImport(UIKit) && !os(watchOS)
        let nc = NotificationCenter.default
        let map: [(Notification.Name, AppLifecycleState)] = [
            (UIApplication.didBecomeActiveNotification, .active),
            (UIApplication.willResignActiveNotification, .inactive),
            (UIApplication.didEnterBackgroundNotification, .background),
        ]
        let added = map.map { name, state in
            nc.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.onAppState(state) }
        }
        withLock {
            if observers.isEmpty { observers = added; return }
            added.forEach { nc.removeObserver($0) } // already observing
        }
        #endif
    }

    /// Stops observing the app lifecycle.
    public func stop() { removeObservers() }

    private func removeObservers() {
        let obs: [NSObjectProtocol] = withLock {
            let o = observers
            observers = []
            return o
        }
        obs.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: Subscriptions

    /// Every link event, including ones that happened before you subscribed.
    @discardableResult
    public func onLink(_ cb: @escaping (LinkEvent) -> Void) -> StraitSubscription {
        let (token, past): (Int, [LinkEvent]) = withLock {
            nextToken += 1
            listeners.append((nextToken, cb))
            return (nextToken, events)
        }
        if !past.isEmpty { deliver { past.forEach(cb) } }
        return StraitSubscription { [weak self] in
            self?.withLock { self?.listeners.removeAll { $0.0 == token } }
        }
    }

    /// A link just arrived and is being resolved (for a loading state).
    @discardableResult
    public func onLinkStart(_ cb: @escaping (LinkStart) -> Void) -> StraitSubscription {
        let token: Int = withLock {
            nextToken += 1
            startListeners.append((nextToken, cb))
            return nextToken
        }
        return StraitSubscription { [weak self] in
            self?.withLock { self?.startListeners.removeAll { $0.0 == token } }
        }
    }

    // MARK: Deferred / fingerprint / events

    /// Re-run the deferred check now (debugging); doesn't touch the once-per-install flag.
    public func checkDeferred(completion: ((LinkEvent) -> Void)? = nil) {
        runDeferred { [self] e in deliver { completion?(e) } }
    }

    /// Send this app's fingerprint to the engine (debug comparison with the browser).
    /// nil on network failure.
    public func reportFingerprint(completion: (([String: Any]?) -> Void)? = nil) {
        var body = config.device().json
        body["publishableKey"] = config.publishableKey
        body["origin"] = "app"
        call("POST", "/v1/debug/fingerprint", body) { [self] r in
            let json = try? r.get().json
            deliver { completion?(json) }
        }
    }

    /// Engine's comparison of the app and browser fingerprints on this network.
    /// nil on network failure.
    public func compareFingerprint(completion: @escaping ([String: Any]?) -> Void) {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        let key = config.publishableKey.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        call("GET", "/v1/debug/fingerprint?publishableKey=\(key)", nil) { [self] r in
            let json = try? r.get().json
            deliver { completion(json) }
        }
    }

    /// Conversion / revenue event. Completes with true when accepted.
    public func trackEvent(
        _ name: String,
        value: Double? = nil,
        currency: String? = nil,
        linkId: String? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        var body: [String: Any] = ["publishableKey": config.publishableKey, "event": name, "platform": config.platform]
        if let value = value { body["value"] = value }
        if let currency = currency { body["currency"] = currency }
        if let linkId = linkId { body["linkId"] = linkId }
        call("POST", "/v1/event", body) { [self] r in
            let ok = (try? r.get().ok) ?? false
            deliver { completion?(ok) }
        }
    }

    // MARK: Internals

    private func handleUrl(_ raw: String, appState: AppStateAtLink, completion: ((LinkEvent) -> Void)?) {
        let t0 = config.now()
        let id = newId(t0)
        announce(LinkStart(id: id, kind: .direct, appState: appState, rawUrl: raw, at: t0))
        let done = { [self] (route: LinkRoute, matched: Bool, reason: String?, dest: Destination, linkId: String?) in
            let e = emit(LinkEvent(
                id: id, kind: .direct, route: route, appState: appState, matched: matched, reason: reason,
                rawUrl: raw, url: dest.url, path: dest.path, params: dest.params, linkId: linkId,
                ms: config.now() - t0, at: t0
            ))
            completion?(e)
        }
        guard let c = classifyUrl(raw, linkHosts: linkHosts) else {
            return done(.appLink, false, "invalid_url", .none, nil)
        }
        switch c {
        case let .destination(route, url, path, params):
            done(route, true, nil, Destination(url: url, path: path, params: params), nil)
        case .shortLink:
            let body: [String: Any] = ["publishableKey": config.publishableKey, "url": raw, "platform": config.platform]
            call("POST", "/v1/resolve", body) { r in
                guard case let .success(res) = r else {
                    return done(.appLink, false, "network", .none, nil)
                }
                let json = res.json
                let matched = (json["matched"] as? Bool) == true
                done(
                    .appLink, matched,
                    matched ? nil : (json["reason"] as? String) ?? (json["error"] as? String),
                    matched ? destination(json["longUrl"] as? String) : .none,
                    json["linkId"] as? String
                )
            }
        }
    }

    private func runDeferred(completion: @escaping (LinkEvent) -> Void) {
        let t0 = config.now()
        let id = newId(t0)
        announce(LinkStart(id: id, kind: .deferred, appState: .closed, rawUrl: nil, at: t0))
        var body = config.device().json
        body["publishableKey"] = config.publishableKey
        body["platform"] = config.platform
        call("POST", "/v1/match", body) { [self] r in
            var matched = false, reason: String? = "network", dest = Destination.none, linkId: String?
            if case let .success(res) = r {
                matched = (res.json["matched"] as? Bool) == true
                reason = matched ? nil : "no_match"
                dest = matched ? destination(res.json["longUrl"] as? String) : .none
                linkId = res.json["linkId"] as? String
            }
            completion(emit(LinkEvent(
                id: id, kind: .deferred, route: .fingerprint, appState: .closed, matched: matched, reason: reason,
                rawUrl: nil, url: dest.url, path: dest.path, params: dest.params, linkId: linkId,
                ms: config.now() - t0, at: t0
            )))
        }
    }

    private struct Reply {
        let ok: Bool
        let status: Int
        let json: [String: Any]
    }

    /// JSON over the transport (bodies built with JSONSerialization — B11).
    private func call(_ method: String, _ path: String, _ body: [String: Any]?, completion: @escaping (Result<Reply, Error>) -> Void) {
        guard let url = URL(string: base + path) else { return completion(.failure(StraitLinksError.badEndpoint)) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body = body {
            guard JSONSerialization.isValidJSONObject(body),
                  let data = try? JSONSerialization.data(withJSONObject: body) else {
                return completion(.failure(StraitLinksError.badBody))
            }
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = data
        }
        config.transport.send(req) { r in
            completion(r.map { res in
                let json = (try? JSONSerialization.jsonObject(with: res.data)) as? [String: Any] ?? [:]
                return Reply(ok: (200..<300).contains(res.status), status: res.status, json: json)
            })
        }
    }

    private func newId(_ at: Double) -> String {
        let n: Int = withLock {
            seq += 1
            return seq
        }
        return "evt_\(Int64(at))_\(n)"
    }

    private func announce(_ s: LinkStart) {
        let cbs = withLock { startListeners.map { $0.1 } }
        deliver { cbs.forEach { $0(s) } }
    }

    private func emit(_ e: LinkEvent) -> LinkEvent {
        let cbs: [(LinkEvent) -> Void] = withLock {
            events.append(e)
            return listeners.map { $0.1 }
        }
        deliver { cbs.forEach { $0(e) } }
        return e
    }

    private func deliver(_ block: @escaping () -> Void) {
        if let q = config.callbackQueue { q.async(execute: block) } else { block() }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

private struct Destination {
    var url: String?
    var path: String?
    var params: [String: String]?
    static let none = Destination()
}

private func destination(_ url: String?) -> Destination {
    guard let url = url else { return .none }
    guard let p = splitUrl(url) else { return Destination(url: url) }
    return Destination(url: url, path: p.path, params: p.params)
}
