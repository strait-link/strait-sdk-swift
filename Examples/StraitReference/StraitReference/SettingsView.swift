import StraitSDK
import SwiftUI

/// What this build is, what Strait says right now, and whether the workspace's
/// apple-app-site-association names this app.
struct SettingsView: View {
    @ObservedObject var model: StraitModel
    @State private var endpoint = ReferenceConfig.endpoint
    @State private var publishableKey = ReferenceConfig.publishableKey
    @State private var asking = false
    @State private var aasa = ""
    @State private var resetDone = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    if let s = model.installSettings {
                        LabeledRow("Method", s.summary, id: "runtimeSummary")
                        LabeledRow("Device matching", s.deviceMatching ? "on" : "off", id: "runtimeDeviceMatching")
                        LabeledRow("Paste handoff", s.pasteHandoff ? "on" : "off", id: "runtimePasteHandoff")
                        LabeledRow("Asked", Date(timeIntervalSince1970: s.at / 1000).formatted(date: .omitted, time: .standard), id: "runtimeAt")
                    } else {
                        Text(model.askResult.isEmpty ? "Not asked yet" : model.askResult).accessibilityIdentifier("runtimeSummary")
                    }
                    Button(asking ? "Asking…" : "Ask Strait now") {
                        asking = true
                        model.askStrait { DispatchQueue.main.async { asking = false } }
                    }
                    .disabled(model.links == nil || asking)
                    .accessibilityIdentifier("askStrait")
                } header: {
                    StraitHeader("Live runtime choice (Dashboard → Settings → iPhone installs)")
                } footer: {
                    StraitFooter("Read from Strait's /v1/match reply, never from this build: flip a switch in the dashboard, tap Ask Strait now, and this changes with no app update. Asking adds no installs.")
                }.straitRows()

                Section {
                    LabeledRow("Bundle ID", ReferenceConfig.bundleId, id: "bundleId")
                    LabeledRow("App ID", ReferenceConfig.appId.nonEmpty ?? "unsigned (no Team ID)", id: "appId")
                    LabeledRow("Associated domain", "applinks:\(ReferenceConfig.linkHost)", id: "associatedDomain")
                    LabeledRow("URL scheme", "\(ReferenceConfig.urlScheme)://", id: "urlScheme")
                    LabeledRow("App Clip", ReferenceConfig.appClipEnabled ? "on (\(ReferenceConfig.appGroup))" : "off", id: "appClip")
                    LabeledRow("SDK", "StraitSDK (this repo)", id: "sdk")
                } header: { StraitHeader("This build") }.straitRows()

                Section {
                    Button("Check apple-app-site-association") { checkAasa() }.accessibilityIdentifier("checkAasa")
                    if !aasa.isEmpty { Text(aasa).font(.footnote.monospaced()).accessibilityIdentifier("aasaResult") }
                } footer: {
                    StraitFooter("Fetches https://\(ReferenceConfig.linkHost)/.well-known/apple-app-site-association directly and checks it lists this App ID. Phones read it through Apple's CDN, which can lag behind.")
                }.straitRows()

                Section {
                    TextField("Endpoint", text: $endpoint).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Publishable key (st_pub_…)", text: $publishableKey)
                    Button("Save and restart the SDK") {
                        ReferenceConfig.save(endpoint: endpoint, publishableKey: publishableKey)
                        model.configure()
                    }
                    Button("Forget the first launch (run the deferred check again)") {
                        ReferenceConfig.resetFirstLaunch()
                        resetDone = true
                    }
                    if resetDone { Text("Done. Quit the app from the app switcher and open it again.").font(.footnote) }
                } header: {
                    StraitHeader("Workspace")
                } footer: {
                    StraitFooter("Only the publishable key belongs in an app. The once-per-install check runs again on the next cold start after Forget; a real first install (delete the app, install from TestFlight) is the stronger test.")
                }.straitRows()
            }
            .straitScreen()
            .navigationTitle("Settings")
        }
        .navigationViewStyle(.stack)
    }

    private func checkAasa() {
        guard let url = URL(string: "https://\(ReferenceConfig.linkHost)/.well-known/apple-app-site-association") else { return }
        aasa = "Fetching…"
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("StraitReference/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let text = Self.describe(data: data, response: response as? HTTPURLResponse, error: error, appId: ReferenceConfig.appId)
            DispatchQueue.main.async { aasa = text }
        }.resume()
    }

    static func describe(data: Data?, response: HTTPURLResponse?, error: Error?, appId: String) -> String {
        guard let response = response else { return "No answer: \(error?.localizedDescription ?? "unknown error")" }
        var lines = ["HTTP \(response.statusCode) \(response.value(forHTTPHeaderField: "Content-Type") ?? "-")"]
        if let final = response.url, final.path != "/.well-known/apple-app-site-association" { lines.append("Redirected to \(final): Apple refuses redirects") }
        guard response.statusCode == 200, let data = data,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            lines.append("No usable file (set the Team ID and bundle ID in the dashboard)")
            return lines.joined(separator: "\n")
        }
        let details = ((json["applinks"] as? [String: Any])?["details"] as? [[String: Any]]) ?? []
        let ids = details.flatMap { ($0["appIDs"] as? [String]) ?? [($0["appID"] as? String)].compactMap { $0 } }
        lines.append("applinks: \(ids.joined(separator: ", "))")
        if let clips = (json["appclips"] as? [String: Any])?["apps"] as? [String] { lines.append("appclips: \(clips.joined(separator: ", "))") }
        if appId.isEmpty {
            lines.append("This build is unsigned, so it has no App ID to compare.")
        } else {
            lines.append(ids.contains(appId) ? "this app: listed" : "this app: NOT listed (\(appId))")
        }
        return lines.joined(separator: "\n")
    }
}
