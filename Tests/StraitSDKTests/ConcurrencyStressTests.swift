import XCTest
@testable import StraitSDK

/// td2-12: many threads hit the public entry points at once, the way a host app's main thread,
/// scene callbacks and URLSession replies do. CI runs this under Thread Sanitizer
/// (`swift test --sanitize=thread`), which fails the run on any data race; without TSan it still
/// catches deadlocks and lost completions.
final class ConcurrencyStressTests: XCTestCase {
    /// An engine that answers every call later, on a background thread, like URLSession.
    final class AsyncEngine: StraitTransport {
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }

        func send(_ request: URLRequest, completion: @escaping (Result<StraitHTTPResponse, Error>) -> Void) {
            lock.lock(); count += 1; let n = count; lock.unlock()
            let payload: [String: Any]
            switch request.url?.path ?? "" {
            case "/v1/match": payload = ["matched": n % 2 == 0, "longUrl": "https://shop.example/p/\(n)", "linkId": "lnk_\(n)"]
            case "/v1/resolve", "/v1/lookup": payload = ["matched": true, "longUrl": "https://shop.example/p/\(n)", "linkId": "lnk_\(n)", "clickId": "c_\(n)"]
            case "/v1/handoff/claim": payload = ["matched": true, "longUrl": "https://shop.example/h/\(n)", "clickId": "h_\(n)"]
            default: payload = ["ok": true]
            }
            // Every 7th call fails like a dropped connection, so the saved queue and retries run too.
            DispatchQueue.global().async {
                if n % 7 == 0 { return completion(.failure(URLError(.networkConnectionLost))) }
                completion(.success(StraitHTTPResponse(status: n % 11 == 0 ? 503 : 200, data: try! JSONSerialization.data(withJSONObject: payload))))
            }
        }
    }

    private func makeLinks(_ engine: AsyncEngine, _ storage: MemoryStorage, _ callbacks: DispatchQueue) -> StraitLinks {
        StraitLinks(StraitLinksConfig(
            publishableKey: "bk_pub_test_appowner01", endpoint: "https://links.test", linkHosts: ["links.test"],
            storage: storage, transport: engine,
            device: { DeviceFields(screenWidth: 393, pixelRatio: 3, language: "en", timezone: "Asia/Kolkata") },
            callbackQueue: callbacks, observeLifecycle: false, pasteboard: SpyPasteboard(),
            deviceClass: "phone", installTime: { nil }, appVersion: "1.0"
        ))
    }

    func testPublicEntryPointsFromManyThreads() {
        let engine = AsyncEngine()
        let storage = MemoryStorage()
        let callbacks = DispatchQueue(label: "strait.stress.callbacks", attributes: .concurrent)
        let strait = makeLinks(engine, storage, callbacks)
        let group = DispatchGroup()
        let seen = NSLock()
        var events = 0
        strait.onLink { _ in seen.lock(); events += 1; seen.unlock() }

        group.enter()
        strait.start(initialURL: nil) { group.leave() }

        let rounds = 400
        DispatchQueue.concurrentPerform(iterations: rounds) { i in
            switch i % 12 {
            case 0: strait.handle(urlString: "https://links.test/s\(i)?utm_source=stress")
            case 1: strait.handle(url: URL(string: "acme://product/\(i)")!)
            case 2:
                let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
                activity.webpageURL = URL(string: "https://links.test/u\(i)")
                strait.handle(userActivity: activity)
            case 3: group.enter(); strait.checkDeferred { _ in group.leave() }
            case 4: group.enter(); strait.trackEvent("purchase", value: Double(i), currency: "INR", eventId: "ord_\(i)") { _ in group.leave() }
            case 5: group.enter(); strait.flushOpenReports { group.leave() }
            case 6: group.enter(); strait.pendingOpenReports { _ in group.leave() }
            case 7: group.enter(); strait.setEnabled(i % 24 != 7) { group.leave() }
            case 8: strait.onAppState([.active, .inactive, .background][i % 3])
            case 9: strait.onLink { _ in }.cancel(); strait.onLinkStart { _ in }.cancel()
            case 10: group.enter(); strait.claimHandoff(text: "https://links.test/h/tok\(i)") { _ in group.leave() }
            default: _ = (strait.isEnabled, strait.lastInstallSettings)
            }
        }
        // Leave the SDK switched on and drained, then every completion must have run.
        group.enter()
        strait.setEnabled(true) { group.leave() }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success, "a completion never ran (deadlock or lost callback)")
        XCTAssertGreaterThan(engine.calls, 0)
        seen.lock(); XCTAssertGreaterThan(events, 0); seen.unlock()
    }

    /// Many instances configured and started at once on one storage (an app that builds the
    /// client in two places), plus the static deferred resolve.
    func testConfigureAndStartFromManyThreads() {
        let engine = AsyncEngine()
        let storage = MemoryStorage()
        let callbacks = DispatchQueue(label: "strait.stress.callbacks2", attributes: .concurrent)
        let group = DispatchGroup()
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            let s = makeLinks(engine, storage, callbacks)
            group.enter()
            s.start(initialURL: i % 4 == 0 ? URL(string: "https://links.test/l\(i)") : nil) { group.leave() }
            group.enter()
            s.setEnabled(i % 5 != 0) { group.leave() }
        }
        let resolves = DispatchGroup()
        for _ in 0..<16 {
            resolves.enter()
            Task.detached {
                _ = await Strait.resolveDeferredLink(
                    StraitConfig(publishableKey: "bk_pub_test_appowner01", endpoint: "http://127.0.0.1:9", appVersion: "1.0"),
                    storage: storage
                )
                resolves.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(resolves.wait(timeout: .now() + 30), .success)
    }
}
