import StoreKit
import StraitSDK
import SwiftUI

/// The reference App Clip (beta). A link on the workspace host opens it with the
/// exact URL; it shows where that link goes, saves the URL in the App Group the
/// full app shares, and offers the full app (SKOverlay). The full app's first
/// launch takes the URL (StraitAppClip.takeInvocation) and opens it.
@main
struct ClipApp: App {
    @StateObject private var state = ClipState()

    var body: some Scene {
        WindowGroup {
            ClipView(state: state)
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { state.invoked($0.webpageURL) }
        }
    }
}

final class ClipState: ObservableObject {
    @Published var invocation: URL?
    @Published var saved = false
    @Published var destination = ""

    private let links: StraitLinks? = {
        let host = Bundle.main.object(forInfoDictionaryKey: "StraitLinkHost") as? String ?? ""
        let pk = Bundle.main.object(forInfoDictionaryKey: "StraitPublishableKey") as? String ?? ""
        guard !host.isEmpty, !pk.isEmpty, !pk.hasPrefix("$(") else { return nil }
        return StraitLinks(StraitLinksConfig(publishableKey: pk, endpoint: "https://\(host)"))
    }()

    func invoked(_ url: URL?) {
        guard let url = url else { return }
        invocation = url
        let group = Bundle.main.object(forInfoDictionaryKey: "StraitAppGroup") as? String ?? ""
        if let store = StraitAppClip.storage(appGroup: group) {
            saved = StraitAppClip.saveInvocation(url, storage: store)
        }
        // Resolve it here too, so the App Clip itself can show the right content.
        guard let links = links else { return }
        _ = links.onLink { [weak self] e in
            DispatchQueue.main.async { self?.destination = e.matched ? (e.path ?? "-") : "no match (\(e.reason ?? "-"))" }
        }
        links.start(initialURL: url)
    }
}

struct ClipView: View {
    @ObservedObject var state: ClipState
    @State private var overlayShown = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Strait reference App Clip").font(.headline)
            Text(state.invocation?.absoluteString ?? "Open me from a link on the workspace host")
                .font(.footnote.monospaced()).multilineTextAlignment(.center).accessibilityIdentifier("clipInvocation")
            if !state.destination.isEmpty { Text("Goes to \(state.destination)").accessibilityIdentifier("clipDestination") }
            Text(state.saved ? "Saved for the full app (App Group)" : "Not saved yet").font(.footnote).accessibilityIdentifier("clipSaved")
            Button("Get the full app") { overlayShown = true }.buttonStyle(.borderedProminent)
        }
        .padding()
        .appStoreOverlay(isPresented: $overlayShown) { SKOverlay.AppClipConfiguration(position: .bottom) }
    }
}
