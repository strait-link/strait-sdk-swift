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

/// Persistent key/value storage for the once-per-install flag and the
/// pending open reports.
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
    /// Workspace publishable key (`st_pub_live_…`), Dashboard → Get started.
    public var publishableKey: String
    /// Your Strait link host, e.g. https://go.yourbrand.com
    public var endpoint: String
    /// Extra hosts that serve your short links (custom domains), as
    /// `https://go.brand.com` or `go.brand.com`.
    public var linkHosts: [String]
    /// Persists `strait.deferredChecked` and `strait.pendingOpens`. Default: `UserDefaults.standard`.
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
    /// Open reports that didn't get through, retried later (JSON array).
    public static let queueKey = "strait.pendingOpens"
    /// The tap id of the last attributed link open, sent with conversion
    /// events for 7 days (contract B15): `{"clickId":…,"at":<ms>}`.
    public static let tapKey = "strait.lastTap"

    private let config: StraitLinksConfig
    private let base: String
    private let linkHosts: [String]
    private let tracker = AppStateTracker()
    private let lock = NSLock()
    /// Serialises every read-modify-write of `strait.lastTap` (B18).
    private let tapLock = NSLock()
    private var events: [LinkEvent] = []
    private var listeners: [(Int, (LinkEvent) -> Void)] = []
    private var startListeners: [(Int, (LinkStart) -> Void)] = []
    private var nextToken = 0
    /// Queue operations waiting to run, one at a time (see `serial`).
    private var queueOps: [(@escaping () -> Void) -> Void] = []
    private var queueBusy = false
    /// Completions of the flush that's queued or running, nil when none.
    private var flushWaiters: [() -> Void]?
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
    /// when the launch itself was a link — and sends any saved open reports.
    public func start(initialURL: URL? = nil, completion: (() -> Void)? = nil) {
        if config.observeLifecycle { observeAppLifecycle() }
        dropStaleTap(now: config.now())
        let firstLaunch = config.storage.getItem(Self.deferredFlag) != "1"
        let finish = { [self] in
            flush(completion: nil)
            deliver { completion?() }
        }
        if let initial = initialURL {
            // Opened by a link on first launch = the user's intent right now: no
            // deferred check, but this open still counts as the install's first.
            if firstLaunch { config.storage.setItem(Self.deferredFlag, "1") }
            handleUrl(initial.absoluteString, appState: .closed, firstLaunch: firstLaunch) { _ in finish() }
        } else if firstLaunch {
            // Marked done only once the engine answered: offline → next launch.
            runDeferred(record: true) { [self] e in
                if e.reason != "network" { config.storage.setItem(Self.deferredFlag, "1") }
                finish()
            }
        } else {
            finish()
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
        handleUrl(urlString, appState: appState, firstLaunch: false, completion: nil)
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
        if state == .active { flush(completion: nil) }
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
        runDeferred(record: false) { [self] e in deliver { completion?(e) } }
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

    /// Conversion / revenue event. Completes with true when accepted. Carries
    /// the tap id of the last attributed link open (≤7 days, contract B15)
    /// unless you pass `clickId` yourself.
    public func trackEvent(
        _ name: String,
        value: Double? = nil,
        currency: String? = nil,
        linkId: String? = nil,
        clickId: String? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        var body: [String: Any] = ["publishableKey": config.publishableKey, "event": name, "platform": config.platform]
        if let value = value { body["value"] = value }
        if let currency = currency { body["currency"] = currency }
        if let linkId = linkId { body["linkId"] = linkId }
        let stored: String? = locked(tapLock) { config.storage.getItem(Self.tapKey) }
        if staleTap(stored, now: config.now()) { dropStaleTap(now: config.now()) }
        if let tap = eventClickId(stored, now: config.now(), explicit: clickId) {
            body["clickId"] = tap
        }
        call("POST", "/v1/event", body) { [self] r in
            let ok = (try? r.get().ok) ?? false
            deliver { completion?(ok) }
        }
    }

    // MARK: Open reports (B14)

    /// Open reports saved while offline, waiting to be sent (debugging).
    public func pendingOpenReports(completion: @escaping (Int) -> Void) {
        serial { [self] done in
            let n = readQueue().count
            done()
            deliver { completion(n) }
        }
    }

    /// Send saved open reports now (also happens on start and whenever the app becomes active).
    public func flushOpenReports(completion: (() -> Void)? = nil) {
        flush { [self] in deliver { completion?() } }
    }

    // MARK: Internals

    /// Remember the tap of an attributed open (B15), or forget the older one
    /// when this newer attributed open has no tap id the SDK knows.
    private func noteTap(_ clickId: String?, at: Double) {
        locked(tapLock) { config.storage.setItem(Self.tapKey, clickId.map { rememberTap($0, at: at) } ?? "") }
    }

    /// B18: delete an expired remembered tap instead of only ignoring it. Re-read
    /// under the tap lock so a newer tap written meanwhile is never lost.
    private func dropStaleTap(now: Double) {
        locked(tapLock) {
            if staleTap(config.storage.getItem(Self.tapKey), now: now) { config.storage.setItem(Self.tapKey, "") }
        }
    }

    private func handleUrl(_ raw: String, appState: AppStateAtLink, firstLaunch: Bool, completion: ((LinkEvent) -> Void)?) {
        let t0 = config.now()
        let id = newOpenId(t0)
        let platform = config.platform
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
        case let .destination(route, url, path, params, clickId):
            if let clickId = clickId { noteTap(clickId, at: t0) }
            // Navigation never waits for the report.
            report(OpenReport(
                openId: id, kind: .direct, route: route, appState: appState, platform: platform, url: reportUrl(url),
                clickId: clickId, linkId: nil, matched: true, reason: nil, firstLaunch: firstLaunch, at: t0
            ))
            done(route, true, nil, Destination(url: url, path: path, params: params), nil)
        case .shortLink:
            // The lookup is also the open report (openId); the engine says whether
            // it recorded it, and anything short of that is retried via /v1/open.
            // B18: only host + path (+ utm_source) leave the device or reach storage.
            let reported = reportUrl(raw)
            let base = OpenReport(
                openId: id, kind: .direct, route: .appLink, appState: appState, platform: platform, url: reported,
                clickId: nil, linkId: nil, matched: false, reason: nil, firstLaunch: firstLaunch, at: t0
            )
            let body: [String: Any] = [
                "publishableKey": config.publishableKey, "url": reported, "platform": platform,
                "openId": id, "appState": appState.rawValue, "firstLaunch": firstLaunch, "at": Int64(t0),
            ]
            call("POST", "/v1/resolve", body) { [self] r in
                guard case let .success(res) = r else {
                    var failed = base
                    failed.reason = "network"
                    enqueue(failed)
                    return done(.appLink, false, "network", .none, nil)
                }
                let json = res.json
                let matched = (json["matched"] as? Bool) == true
                let reason = matched ? nil : (json["reason"] as? String) ?? (json["error"] as? String)
                let linkId = json["linkId"] as? String
                if matched { noteTap(replyClickId(json["clickId"]), at: t0) }
                if (json["recorded"] as? Bool) != true {
                    var rep = base
                    rep.matched = matched
                    rep.reason = reason
                    rep.linkId = linkId
                    report(rep)
                }
                done(.appLink, matched, reason, matched ? destination(json["longUrl"] as? String) : .none, linkId)
            }
        }
    }

    /// The deferred check. `record` (the once-per-install run) sends the openId so
    /// the engine records this first open + install exactly once; the debug
    /// re-check doesn't, so it never adds installs.
    private func runDeferred(record: Bool, completion: @escaping (LinkEvent) -> Void) {
        let t0 = config.now()
        let id = newOpenId(t0)
        announce(LinkStart(id: id, kind: .deferred, appState: .closed, rawUrl: nil, at: t0))
        var body = config.device().json
        body["publishableKey"] = config.publishableKey
        body["platform"] = config.platform
        if record {
            body["openId"] = id
            body["at"] = Int64(t0) // whole ms, like the other SDKs
        }
        call("POST", "/v1/match", body) { [self] r in
            // No answer, 429 or 5xx = try again next launch (reported as 'network').
            var matched = false, reason: String? = "network", dest = Destination.none, linkId: String?
            if case let .success(res) = r, !shouldRetryReport(res.status) {
                matched = (res.json["matched"] as? Bool) == true
                reason = matched ? nil : "no_match"
                dest = matched ? destination(res.json["longUrl"] as? String) : .none
                linkId = res.json["linkId"] as? String
                if record && matched { noteTap(replyClickId(res.json["clickId"]), at: t0) }
            }
            completion(emit(LinkEvent(
                id: id, kind: .deferred, route: .fingerprint, appState: .closed, matched: matched, reason: reason,
                rawUrl: nil, url: dest.url, path: dest.path, params: dest.params, linkId: linkId,
                ms: config.now() - t0, at: t0
            )))
        }
    }

    /// Run queue operations one at a time (each calls `done` when finished),
    /// so a flush and a new report never overwrite each other's writes.
    private func serial(_ op: @escaping (@escaping () -> Void) -> Void) {
        let start: Bool = withLock {
            queueOps.append(op)
            if queueBusy { return false }
            queueBusy = true
            return true
        }
        if start { runNextOp() }
    }

    private func runNextOp() {
        let op: ((@escaping () -> Void) -> Void)? = withLock {
            if queueOps.isEmpty {
                queueBusy = false
                return nil
            }
            return queueOps.removeFirst()
        }
        op? { [self] in runNextOp() }
    }

    private func readQueue() -> [OpenReport] {
        guard let raw = config.storage.getItem(Self.queueKey), let data = raw.data(using: .utf8) else { return [] }
        // B18: reports saved by an older SDK may hold a full URL; strip it here
        // so the next write leaves no query or fragment on the device.
        return ((try? JSONDecoder().decode([OpenReport].self, from: data)) ?? []).map { rep in
            var r = rep
            r.url = rep.url.map(reportUrl)
            return r
        }
    }

    private func writeQueue(_ q: [OpenReport]) {
        guard let data = try? JSONEncoder().encode(q), let raw = String(data: data, encoding: .utf8) else { return }
        config.storage.setItem(Self.queueKey, raw)
    }

    private func enqueue(_ report: OpenReport) {
        serial { [self] done in
            writeQueue(pruneOpenQueue(readQueue() + [report], now: config.now()) { Double($0.at) })
            done()
        }
    }

    /// POST /v1/open; completes with the HTTP status, or nil when there was no answer.
    private func sendReport(_ report: OpenReport, completion: @escaping (Int?) -> Void) {
        guard let data = try? JSONEncoder().encode(report),
              var body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return completion(400) // can't happen; never retry a report that can't be built
        }
        body["publishableKey"] = config.publishableKey
        call("POST", "/v1/open", body) { r in
            completion(try? r.get().status)
        }
    }

    /// Report an open now; keep it for retry if it doesn't get through.
    private func report(_ rep: OpenReport) {
        sendReport(rep) { [self] status in
            if shouldRetryReport(status) { enqueue(rep) } else { flush(completion: nil) } // the network works
        }
    }

    private func flush(completion: (() -> Void)?) {
        let start: Bool = withLock {
            if flushWaiters != nil {
                if let c = completion { flushWaiters?.append(c) }
                return false
            }
            flushWaiters = completion.map { [$0] } ?? []
            return true
        }
        guard start else { return }
        serial { [self] done in
            let queue = pruneOpenQueue(readQueue(), now: config.now()) { Double($0.at) }
            var keep: [OpenReport] = []
            func next(_ i: Int) {
                guard i < queue.count else {
                    writeQueue(keep)
                    let waiters: [() -> Void] = withLock {
                        let w = flushWaiters ?? []
                        flushWaiters = nil
                        return w
                    }
                    done()
                    waiters.forEach { $0() }
                    return
                }
                sendReport(queue[i]) { status in
                    if shouldRetryReport(status) { keep.append(queue[i]) }
                    // Once one gets no answer at all, keep the rest for later.
                    if status == nil {
                        keep.append(contentsOf: queue[(i + 1)...])
                        return next(queue.count)
                    }
                    next(i + 1)
                }
            }
            next(0)
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

/// Runs `body` holding `lock` (NSLocking.withLock needs iOS 16 / macOS 13).
private func locked<T>(_ lock: NSLock, _ body: () throws -> T) rethrows -> T {
    lock.lock(); defer { lock.unlock() }
    return try body()
}

/// One app open as reported to POST /v1/open (contract B14); also the
/// stored shape in `strait.pendingOpens`.
struct OpenReport: Codable {
    var openId: String
    var kind: String
    var route: String
    var appState: String
    var platform: String
    var url: String?
    var clickId: String?
    var linkId: String?
    var matched: Bool
    var reason: String?
    var firstLaunch: Bool
    var at: Int64 // whole ms

    init(
        openId: String, kind: LinkKind, route: LinkRoute, appState: AppStateAtLink, platform: String,
        url: String?, clickId: String?, linkId: String?, matched: Bool, reason: String?, firstLaunch: Bool, at: Double
    ) {
        self.openId = openId
        self.kind = kind.rawValue
        self.route = route.rawValue
        self.appState = appState.rawValue
        self.platform = platform
        self.url = url
        self.clickId = clickId
        self.linkId = linkId
        self.matched = matched
        self.reason = reason
        self.firstLaunch = firstLaunch
        self.at = Int64(at)
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
