import StraitSDK
import SwiftUI
import UIKit

/// Config comes from the launch environment (UI tests, `simctl launch` with
/// SIMCTL_CHILD_STRAIT_*) and is remembered so a cold launch by `simctl openurl`
/// still has it. Never hard-code a real key here.
enum SimConfig {
    static let d = UserDefaults.standard
    static func value(_ key: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty {
            d.set(v, forKey: "simverify.\(key)")
            return v
        }
        return d.string(forKey: "simverify.\(key)")
    }

    static func resetIfAsked() {
        guard ProcessInfo.processInfo.environment["STRAIT_RESET"] == "1" else { return }
        for key in [StraitLinks.deferredFlag, StraitLinks.queueKey, StraitLinks.tapKey] { d.removeObject(forKey: key) }
    }
}

final class LinkLog: ObservableObject {
    @Published var lines: [String] = []
    @Published var last = "none"
    @Published var starts = 0

    static func describe(_ e: LinkEvent) -> String {
        let params = (e.params ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return "kind=\(e.kind.rawValue) route=\(e.route.rawValue) state=\(e.appState.rawValue) matched=\(e.matched)"
            + " reason=\(e.reason ?? "-") path=\(e.path ?? "-") params=\(params.isEmpty ? "-" : params)"
            + " linkId=\(e.linkId == nil ? "-" : "yes")"
    }
}

@main
struct SimVerifyApp: App {
    @StateObject private var log = LinkLog()
    private let links: StraitLinks?

    init() {
        SimConfig.resetIfAsked()
        let endpoint = SimConfig.value("STRAIT_ENDPOINT") ?? ""
        let pk = SimConfig.value("STRAIT_PK") ?? ""
        let boost = ProcessInfo.processInfo.environment["STRAIT_BOOST"] == "1"
        links = endpoint.isEmpty || pk.isEmpty ? nil : StraitLinks(StraitLinksConfig(
            publishableKey: pk, endpoint: endpoint, clipboardBoost: boost
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(links: links, log: log)
                .onAppear {
                    guard let links = links else { return }
                    links.onLinkStart { _ in log.starts += 1 }
                    links.onLink { e in
                        let s = LinkLog.describe(e)
                        log.lines.insert(s, at: 0)
                        log.last = s
                        print("SIMVERIFY_EVENT \(s)")
                    }
                    links.start()
                }
                .onOpenURL { links?.handle(url: $0) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { links?.handle(userActivity: $0) }
        }
    }
}

struct ContentView: View {
    let links: StraitLinks?
    @ObservedObject var log: LinkLog

    var body: some View {
        NavigationView {
            List {
                Section("Status") {
                    Text(links == nil ? "Not configured (set STRAIT_ENDPOINT + STRAIT_PK)" : "SDK started")
                    Text(log.last).font(.footnote.monospaced()).accessibilityIdentifier("lastEvent")
                    Text("events=\(log.lines.count) starts=\(log.starts)").accessibilityIdentifier("eventCount")
                }
                if let links = links, #available(iOS 16.0, *) {
                    Section("Paste handoff (no prompt)") {
                        PasteControl(links: links).frame(height: 44)
                    }
                }
                Section("Events") {
                    ForEach(Array(log.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("Strait SimVerify")
        }
        .navigationViewStyle(.stack)
    }
}

@available(iOS 16.0, *)
struct PasteControl: UIViewRepresentable {
    let links: StraitLinks
    func makeUIView(context: Context) -> StraitPasteButton {
        let b = StraitPasteButton(straitLinks: links)
        b.accessibilityIdentifier = "straitPaste"
        return b
    }

    func updateUIView(_ uiView: StraitPasteButton, context: Context) {}
}
