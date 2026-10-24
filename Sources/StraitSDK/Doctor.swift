import Foundation

// MARK: - doctor(): a setup check for debug builds (contract B23, shared-spec ADR 0002)

/// One line of the setup check. `severity` is "ok", "warn" or "error"; `fix` is empty for "ok".
/// Ids and wording are the same in every Strait SDK.
public struct DoctorFinding: Equatable {
    public let id: String
    public let severity: String
    public let title: String
    public let fix: String
    public init(id: String, severity: String, title: String, fix: String) {
        self.id = id
        self.severity = severity
        self.title = title
        self.fix = fix
    }
}

/// `ok` = no "error" finding.
public struct DoctorReport: Equatable {
    public let ok: Bool
    public let findings: [DoctorFinding]
    public init(ok: Bool, findings: [DoctorFinding]) {
        self.ok = ok
        self.findings = findings
    }
}

/// What the link host answered for the platform's file: `status` nil = the request failed (network).
public struct DoctorFile: Equatable {
    public let status: Int?
    public let body: String?
    public init(status: Int?, body: String?) {
        self.status = status
        self.body = body
    }
}

/// The checks behind `doctor()`, pure: the key, the endpoint, then (when the endpoint is valid) the
/// file the host served and the app identity. `platform` is "ios" (this SDK reads
/// `apple-app-site-association`); `appId` is the bundle ID, nil when unknown; `file` is nil when the
/// endpoint was invalid (nothing was fetched).
public func doctorFindings(publishableKey: String, endpoint: String, platform: String, appId: String?, file: DoctorFile?) -> [DoctorFinding] {
    var out: [DoctorFinding] = []
    func ok(_ id: String, _ title: String) { out.append(DoctorFinding(id: id, severity: "ok", title: title, fix: "")) }
    func error(_ id: String, _ title: String, _ fix: String) { out.append(DoctorFinding(id: id, severity: "error", title: title, fix: fix)) }

    if publishableKey.hasPrefix("st_pub_") {
        ok("key.ok", "Publishable key is set")
    } else if publishableKey.hasPrefix("st_live_") || publishableKey.hasPrefix("st_test_") {
        error("key.secret", "This is a secret key, not the publishable key",
              "Use the publishable key (st_pub_…) from Dashboard → Get started, and revoke this secret key in Dashboard → Settings → Secret keys: it has been inside your app.")
    } else {
        error("key.invalid", "Not a publishable key", "Copy the publishable key (st_pub_…) from Dashboard → Get started.")
    }

    guard let host = doctorHost(endpoint) else {
        error("endpoint.invalid", "The endpoint isn't an https link domain",
              "Set endpoint to your link domain from Dashboard → Get started, e.g. https://<handle>.strait.link.")
        return out
    }
    guard let status = file?.status else {
        error("host.unreachable", "Can't reach \(host)",
              "Check that endpoint is your link domain (Dashboard → Get started) and that this device is online.")
        return out
    }
    guard status == 200, let ids = aasaAppIDs(file?.body) else {
        error("host.file_missing", "\(host) doesn't serve apple-app-site-association",
              "Use your Strait link domain as endpoint (Dashboard → Get started); Strait serves this file there.")
        return out
    }
    let listed = ids.joined(separator: ", ")
    if ids.isEmpty {
        error("app.none", "No \(platform == "ios" ? "iOS" : platform) app is set up for \(host)", "Add your app in Dashboard → Apps & stores.")
    } else if let app = appId, !app.isEmpty {
        // iOS can't read its Team ID at runtime: match the bundle ID suffix, show the full appID.
        if let match = ids.first(where: { $0.hasSuffix("." + app) }) {
            ok("app.listed", "\(host) lists \(match)")
        } else {
            error("app.missing", "\(host) doesn't list \(app)", "Add \(app) in Dashboard → Apps & stores (listed now: \(listed)).")
        }
    } else {
        out.append(DoctorFinding(id: "app.unknown", severity: "warn", title: "\(host) lists \(listed)", fix: "Make sure your app is one of these."))
    }
    return out
}

/// The endpoint's host when it is an `https://` URL with a host, else nil.
private func doctorHost(_ endpoint: String) -> String? {
    guard let url = URL(string: endpoint), url.scheme?.lowercased() == "https",
          let host = url.host, !host.isEmpty else { return nil }
    return host
}

/// Every appID in `applinks.details[]` (`appIDs` and the legacy `appID`), in order, once each;
/// nil when the body isn't an apple-app-site-association JSON.
private func aasaAppIDs(_ body: String?) -> [String]? {
    guard let data = body?.data(using: .utf8),
          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let applinks = json["applinks"] as? [String: Any] else { return nil }
    var ids: [String] = []
    for detail in applinks["details"] as? [[String: Any]] ?? [] {
        for id in (detail["appIDs"] as? [String] ?? []) + [detail["appID"] as? String].compactMap({ $0 }) where !ids.contains(id) {
            ids.append(id)
        }
    }
    return ids
}

extension StraitLinks {
    /// Checks this app's Strait setup (contract B23): one GET of
    /// `{endpoint}/.well-known/apple-app-site-association`, then `doctorFindings`. Call it from a
    /// debug build; it never runs by itself, never throws, prints each finding and completes on
    /// the config's callback queue.
    public func doctor(bundleId: String? = Bundle.main.bundleIdentifier, completion: @escaping (DoctorReport) -> Void) {
        let finish = { [self] (file: DoctorFile?) in
            let findings = doctorFindings(publishableKey: config.publishableKey, endpoint: config.endpoint,
                                          platform: "ios", appId: bundleId, file: file)
            findings.forEach { print("[Strait doctor] \($0.severity): \($0.title)\($0.fix.isEmpty ? "" : ". \($0.fix)")") }
            let report = DoctorReport(ok: !findings.contains { $0.severity == "error" }, findings: findings)
            deliver { completion(report) }
        }
        guard doctorHost(config.endpoint) != nil,
              let url = URL(string: base + "/.well-known/apple-app-site-association") else { return finish(nil) }
        config.transport.send(URLRequest(url: url)) { r in
            switch r {
            case let .success(res): finish(DoctorFile(status: res.status, body: String(data: res.data, encoding: .utf8)))
            case .failure: finish(DoctorFile(status: nil, body: nil))
            }
        }
    }
}
