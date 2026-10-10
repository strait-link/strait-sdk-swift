import Foundation
import StraitSDK
import UIKit

/// One StraitLinks client for the app's lifetime, plus what the screens show.
final class StraitModel: ObservableObject {
    static let shared = StraitModel()

    @Published private(set) var links: StraitLinks?
    @Published private(set) var events: [String] = []
    /// The newest event as one machine-readable line (UI tests read it).
    @Published private(set) var lastEvent = "none"
    /// Where the app navigated for the newest matched link (path + params).
    @Published private(set) var screen = "Home"
    @Published private(set) var started = false
    /// Where the launch link came from: "universal link", "custom scheme", "App Clip" or "none".
    @Published private(set) var launchSource = "none"
    @Published private(set) var installSettings: InstallSettings?
    /// Strait answered /v1/match but its reply had no `ios` choice (an engine
    /// older than the runtime-choice release), or it could not be reached.
    @Published private(set) var askResult = ""

    private var subscriptions: [StraitSubscription] = []

    private init() { configure() }

    /// (Re)creates the client from ReferenceConfig. Called again after Settings changes.
    func configure() {
        subscriptions.forEach { $0.cancel() }
        subscriptions = []
        links?.stop()
        let endpoint = ReferenceConfig.endpoint, pk = ReferenceConfig.publishableKey
        guard !endpoint.isEmpty, !pk.isEmpty else {
            links = nil
            return
        }
        let client = StraitLinks(StraitLinksConfig(publishableKey: pk, endpoint: endpoint))
        subscriptions.append(client.onLink { [weak self] e in self?.record(e) })
        links = client
    }

    func start(launchURL: URL?) {
        guard let links = links, !started else { return }
        started = true
        var initial = launchURL
        if let url = launchURL {
            launchSource = url.scheme == "https" ? "universal link" : "custom scheme"
        } else if ReferenceConfig.appClipEnabled,
                  let group = StraitAppClip.storage(appGroup: ReferenceConfig.appGroup),
                  let clipURL = StraitAppClip.takeInvocation(storage: group) {
            // Installed after the App Clip: its exact link, no deferred check.
            initial = clipURL
            launchSource = "App Clip"
        }
        links.start(initialURL: initial) { [weak self] in self?.refreshSettings() }
    }

    func handle(userActivity: NSUserActivity) { links?.handle(userActivity: userActivity) }
    func handle(url: URL) { links?.handle(url: url) }

    /// Ask Strait now (`/v1/match` without recording an install) and show the
    /// workspace's live iPhone choice. Adds no installs.
    func askStrait(completion: (() -> Void)? = nil) {
        guard let links = links else { return }
        links.checkDeferred { [weak self] e in
            guard let self = self else { return }
            let settings = self.links?.lastInstallSettings
            DispatchQueue.main.async {
                self.installSettings = settings
                if e.reason == "network" {
                    self.askResult = "Strait could not be reached"
                } else if settings == nil {
                    self.askResult = "Strait answered without the iPhone choice (engine older than the runtime-choice release)"
                } else {
                    self.askResult = "Strait answered"
                }
                completion?()
            }
        }
    }

    func refreshSettings() {
        DispatchQueue.main.async { self.installSettings = self.links?.lastInstallSettings }
    }

    private func record(_ e: LinkEvent) {
        let line = Self.describe(e)
        print("STRAIT_REF_EVENT \(line)") // visible in the device console / xcodebuild log
        DispatchQueue.main.async {
            self.events.insert(line, at: 0)
            self.lastEvent = line
            if e.matched, let path = e.path {
                let params = (e.params ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
                self.screen = params.isEmpty ? path : "\(path)?\(params)"
            }
            self.installSettings = self.links?.lastInstallSettings ?? self.installSettings
        }
    }

    static func describe(_ e: LinkEvent) -> String {
        let params = (e.params ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return "kind=\(e.kind.rawValue) route=\(e.route.rawValue) state=\(e.appState.rawValue) matched=\(e.matched)"
            + " reason=\(e.reason ?? "-") path=\(e.path ?? "-") params=\(params.isEmpty ? "-" : params)"
            + " linkId=\(e.linkId == nil ? "-" : "yes") ms=\(Int(e.ms))"
    }
}
