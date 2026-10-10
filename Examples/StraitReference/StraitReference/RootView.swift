import StraitSDK
import StoreKit
import SwiftUI
import UIKit

struct RootView: View {
    @ObservedObject var model: StraitModel

    var body: some View {
        TabView {
            LinksView(model: model).tabItem { Label("Links", systemImage: "link") }
            StoreSheetView(model: model).tabItem { Label("Store sheet", systemImage: "bag") }
            PasteView(model: model).tabItem { Label("Paste", systemImage: "doc.on.clipboard") }
            SettingsView(model: model).tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

// MARK: Links

struct LinksView: View {
    @ObservedObject var model: StraitModel
    @State private var selfCheck = ""

    var body: some View {
        NavigationView {
            List {
                Section("Status") {
                    Text(model.links == nil ? "Not configured: add the publishable key in Settings" : "SDK started")
                        .accessibilityIdentifier("sdkStatus")
                    LabeledRow("Screen", model.screen, id: "screen")
                    LabeledRow("Launch link", model.launchSource, id: "launchSource")
                    Text(model.lastEvent).font(.footnote.monospaced()).accessibilityIdentifier("lastEvent")
                    Text("events=\(model.events.count)").accessibilityIdentifier("eventCount")
                }.straitRows()
                Section {
                    Button("Open https://\(ReferenceConfig.linkHost)/ref-test") { openOwnLink() }
                        .accessibilityIdentifier("selfCheck")
                    if !selfCheck.isEmpty { Text(selfCheck).font(.footnote).accessibilityIdentifier("selfCheckResult") }
                } header: {
                    Text("Universal Link self-check")
                } footer: {
                    Text("Asks iOS to open a link on the workspace host as a Universal Link only. \"Claimed\" means this phone downloaded the AASA and links on this host open this app. Real taps still need the Notes / Messages test.")
                }.straitRows()
                Section("Events (newest first)") {
                    ForEach(Array(model.events.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }.straitRows()
            }
            .straitScreen()
            .navigationTitle("Strait reference")
        }
        .navigationViewStyle(.stack)
    }

    private func openOwnLink() {
        guard !ReferenceConfig.linkHost.isEmpty, let url = URL(string: "https://\(ReferenceConfig.linkHost)/ref-test") else { return }
        UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { ok in
            selfCheck = ok ? "Claimed: iOS treats this host as a Universal Link for an installed app."
                : "Not claimed: no installed app has this host verified (check the Team ID, the AASA and the Associated Domains entitlement)."
        }
    }
}

// MARK: Store sheet

struct StoreSheetView: View {
    @ObservedObject var model: StraitModel
    @State private var link = "https://\(ReferenceConfig.linkHost)/"
    @State private var appStoreId = ""
    @State private var result = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Short link", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("storeLink")
                    TextField("App Store ID (optional override)", text: $appStoreId).keyboardType(.numberPad)
                } footer: {
                    Text("One of your Strait links. The engine records the tap and answers the App Store ID (Dashboard → Settings → App configuration), then the SDK shows the App Store inside this app and keeps the deep link for the app being installed.")
                }.straitRows()
                Section {
                    Button("Show product page (SKStoreProductViewController)") { open(.productPage) }
                        .accessibilityIdentifier("storeProductPage")
                    Button("Show overlay (SKOverlay)") { open(.overlay) }
                        .accessibilityIdentifier("storeOverlay")
                }.straitRows()
                if !result.isEmpty {
                    Section("Result") { Text(result).font(.footnote.monospaced()).accessibilityIdentifier("storeResult") }.straitRows()
                }
            }
            .straitScreen()
            .navigationTitle("Store sheet (beta)")
        }
        .navigationViewStyle(.stack)
    }

    private func open(_ style: StoreSheetStyle) {
        guard let links = model.links, let host = topViewController() else { result = "Not configured"; return }
        let options = StoreSheetOptions(appStoreId: appStoreId.nonEmpty, style: style)
        links.openStoreSheet(url: link.trimmingCharacters(in: .whitespaces), options: options,
                             presenter: SystemStoreSheetPresenter(from: host)) { r in
            DispatchQueue.main.async {
                result = "opened=\(r.opened) method=\(r.method) matchSaved=\(r.matchSaved) reason=\(r.reason ?? "-")"
            }
        }
    }
}

// MARK: Paste

struct PasteView: View {
    @ObservedObject var model: StraitModel
    @State private var likely: Bool?

    var body: some View {
        NavigationView {
            List {
                Section {
                    if let links = model.links {
                        PasteControl(links: links).frame(height: 44)
                    } else {
                        Text("Not configured")
                    }
                } header: {
                    Text("Apple's Paste button (no prompt)")
                } footer: {
                    Text("Claims a Strait handoff link (https://<host>/h/<token>) the person copied with \"Get the app\". The tap is the consent, so iOS shows no \"Allow Paste\" prompt. It works whatever the dashboard switches say.")
                }.straitRows()
                Section("Clipboard check (no prompt)") {
                    Button("Does the clipboard hold a web link?") {
                        model.links?.handoffAvailable { v in DispatchQueue.main.async { likely = v } }
                    }
                    if let likely = likely { Text(likely ? "Probably a web link" : "No web link").accessibilityIdentifier("handoffAvailable") }
                }.straitRows()
                Section("Last event") {
                    Text(model.lastEvent).font(.footnote.monospaced())
                }.straitRows()
            }
            .straitScreen()
            .navigationTitle("Paste handoff")
        }
        .navigationViewStyle(.stack)
    }
}

struct PasteControl: UIViewRepresentable {
    let links: StraitLinks
    func makeUIView(context: Context) -> StraitPasteButton {
        let b = StraitPasteButton(straitLinks: links)
        b.accessibilityIdentifier = "straitPaste"
        return b
    }

    func updateUIView(_ uiView: StraitPasteButton, context: Context) {}
}

// MARK: Shared

struct LabeledRow: View {
    let title: String
    let value: String
    let id: String
    init(_ title: String, _ value: String, id: String) {
        self.title = title
        self.value = value
        self.id = id
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(value).foregroundColor(Color.strait(\.textMuted)).multilineTextAlignment(.trailing).accessibilityIdentifier(id)
        }
    }
}

func topViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
}
