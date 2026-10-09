import Foundation
#if os(iOS) && canImport(StoreKit)
import StoreKit
import UIKit
#endif

// Store sheet (beta; the iPhone side of Strait is beta). Show the App Store
// INSIDE your app for one of your Strait links, and keep the deep link across
// the install:
//
// 1. The engine records the tap (POST /v1/store-sheet, sent_to 'store_sheet')
//    and answers the App Store id, the link's campaign (the `ct` token) and,
//    when the workspace turned the clipboard boost on, a one-time handoff link.
// 2. The SDK saves this device's match fields for that tap (POST /v1/match-save),
//    so the installed app's normal deferred check (/v1/match) finds it. With
//    `copyHandoffLink` it also copies the handoff link; an installed app with
//    `clipboardBoost: true` claims it for an exact match.
// 3. The SDK shows SKStoreProductViewController (a full product page as a
//    sheet) or SKOverlay (a small banner) through a `StoreSheetPresenting`.
//
// This works only where YOUR app is the host. A link tapped inside another
// company's app can't open a store sheet there.

/// How the App Store appears inside your app.
public enum StoreSheetStyle: String, Equatable {
    /// `SKStoreProductViewController`: the full product page as a modal sheet.
    case productPage = "product_page"
    /// `SKOverlay` (iOS 14+): a small card at the bottom of the screen.
    case overlay
}

/// What the App Store is asked to show.
public struct StoreProduct: Equatable {
    public let appStoreId: String
    /// App Store campaign token (`ct`), at most 30 characters here.
    public let campaignToken: String?
    /// Your App Store Connect provider token (`pt`), if you use one.
    public let providerToken: String?
    /// A custom product page id (iOS 15+), if you made one in App Store Connect.
    public let customProductPageId: String?

    public init(appStoreId: String, campaignToken: String? = nil, providerToken: String? = nil, customProductPageId: String? = nil) {
        self.appStoreId = appStoreId
        self.campaignToken = campaignToken
        self.providerToken = providerToken
        self.customProductPageId = customProductPageId
    }
}

public struct StoreSheetOptions {
    /// The app to install. Default: the link workspace's App Store id from the engine.
    public var appStoreId: String?
    public var providerToken: String?
    public var customProductPageId: String?
    public var style: StoreSheetStyle
    /// Save this device's match fields for the tap (POST /v1/match-save). Default true.
    public var saveDeviceMatch: Bool
    /// Copy the engine's one-time handoff link to the clipboard (only when the
    /// workspace's clipboard boost is on). Default false: it replaces what the
    /// user had copied, so turn it on only when that is acceptable in your app.
    public var copyHandoffLink: Bool

    public init(appStoreId: String? = nil, providerToken: String? = nil, customProductPageId: String? = nil,
                style: StoreSheetStyle = .productPage, saveDeviceMatch: Bool = true, copyHandoffLink: Bool = false) {
        self.appStoreId = appStoreId
        self.providerToken = providerToken
        self.customProductPageId = customProductPageId
        self.style = style
        self.saveDeviceMatch = saveDeviceMatch
        self.copyHandoffLink = copyHandoffLink
    }
}

public struct StoreSheetResult: Equatable {
    /// True when the App Store sheet or overlay was shown.
    public let opened: Bool
    /// "product_page", "overlay" or "none".
    public let method: String
    /// The Strait tap id (nil when the engine couldn't be reached).
    public let clickId: String?
    public let linkId: String?
    /// The device's match fields were saved for this tap.
    public let matchSaved: Bool
    /// The handoff link was copied to the clipboard.
    public let handoffCopied: Bool
    /// Why the deep link is not kept or nothing opened: not_found, expired, offline, no_app_store_id, not_shown…
    public let reason: String?
}

/// Shows the App Store for a product. Call `completion(true)` once it is on screen.
public protocol StoreSheetPresenting {
    func present(_ product: StoreProduct, style: StoreSheetStyle, completion: @escaping (Bool) -> Void)
}

/// A clipboard the SDK may write to (store sheet handoff link only).
public protocol StraitPasteboardWriting {
    func writeString(_ value: String)
}

extension SystemPasteboard: StraitPasteboardWriting {
    public func writeString(_ value: String) {
        #if canImport(UIKit) && !os(watchOS) && !os(tvOS)
        UIPasteboard.general.string = value
        #endif
    }
}

public enum StoreSheet {
    /// Apple's campaign token, as sent to the App Store.
    public static let campaignTokenMax = 30

    /// A numeric App Store id ("6474676842").
    public static func isAppStoreId(_ s: String?) -> Bool {
        guard let s = s, !s.isEmpty, s.count <= 20 else { return false }
        return s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The product to show from the engine's `ios` reply and your options (options win).
    public static func product(reply ios: [String: Any]?, options: StoreSheetOptions) -> StoreProduct? {
        let id = options.appStoreId ?? (ios?["appStoreId"] as? String)
        guard isAppStoreId(id) else { return nil }
        let ct = (ios?["campaignToken"] as? String).map { String($0.prefix(campaignTokenMax)) }
        return StoreProduct(appStoreId: id!, campaignToken: ct, providerToken: options.providerToken,
                            customProductPageId: options.customProductPageId)
    }

    /// An https handoff link of the shape the engine mints (`https://<host>/h/<22 chars>`), else nil.
    public static func handoffLink(_ v: Any?) -> String? {
        guard let s = v as? String, let host = URL(string: s)?.host,
              parseHandoffUrl(s, linkHosts: [host]) != nil else { return nil }
        return s
    }
}

extension StraitLinks {
    /// Store sheet (beta): show the App Store inside your app for one of your
    /// short links, keeping the deep link for the app being installed.
    /// `completion` runs on the config's callback queue.
    public func openStoreSheet(url: String, options: StoreSheetOptions = StoreSheetOptions(),
                               presenter: StoreSheetPresenting, completion: ((StoreSheetResult) -> Void)? = nil) {
        let body: [String: Any] = ["publishableKey": config.publishableKey, "url": url, "platform": "ios"]
        call("POST", "/v1/store-sheet", body) { [self] r in
            var reason: String?
            var ios: [String: Any]?
            var clickId: String?
            var linkId: String?
            switch r {
            case let .success(reply) where reply.ok && (reply.json["ok"] as? Bool) == true:
                ios = reply.json["ios"] as? [String: Any]
                clickId = reply.json["clickId"] as? String
                linkId = reply.json["linkId"] as? String
            case let .success(reply):
                reason = (reply.json["reason"] as? String) ?? "http_\(reply.status)"
            case .failure:
                reason = "offline"
            }
            guard let product = StoreSheet.product(reply: ios, options: options) else {
                let res = StoreSheetResult(opened: false, method: "none", clickId: clickId, linkId: linkId,
                                           matchSaved: false, handoffCopied: false, reason: reason ?? "no_app_store_id")
                return deliver { completion?(res) }
            }
            var copied = false
            if options.copyHandoffLink, let link = StoreSheet.handoffLink(ios?["handoffUrl"]),
               let writer = config.pasteboard as? StraitPasteboardWriting {
                writer.writeString(link)
                copied = true
            }
            let show = { (saved: Bool) in
                presenter.present(product, style: options.style) { shown in
                    let res = StoreSheetResult(opened: shown, method: shown ? options.style.rawValue : "none",
                                               clickId: clickId, linkId: linkId, matchSaved: saved,
                                               handoffCopied: copied, reason: shown ? reason : (reason ?? "not_shown"))
                    self.deliver { completion?(res) }
                }
            }
            let matching = (ios?["deviceMatching"] as? Bool) ?? false
            guard options.saveDeviceMatch, matching, let lid = linkId, let cid = clickId else { return show(false) }
            var save = config.device().json
            save["linkId"] = lid
            save["clickId"] = cid
            call("POST", "/v1/match-save", save) { r in
                show((try? r.get().ok) ?? false)
            }
        }
    }
}

extension Strait {
    /// Store sheet (beta): same as `StraitLinks.openStoreSheet`.
    public static func openStoreSheet(_ links: StraitLinks, url: String, options: StoreSheetOptions = StoreSheetOptions(),
                                      presenter: StoreSheetPresenting, completion: ((StoreSheetResult) -> Void)? = nil) {
        links.openStoreSheet(url: url, options: options, presenter: presenter, completion: completion)
    }
}

#if os(iOS) && canImport(StoreKit)
/// The real presenter: `SKStoreProductViewController` from `viewController`,
/// or `SKOverlay` in its window scene (iOS 14+; earlier falls back to the product page).
public final class SystemStoreSheetPresenter: NSObject, StoreSheetPresenting, SKStoreProductViewControllerDelegate {
    private weak var viewController: UIViewController?

    public init(from viewController: UIViewController) {
        self.viewController = viewController
    }

    public func present(_ product: StoreProduct, style: StoreSheetStyle, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async { [self] in
            guard let host = viewController else { return completion(false) }
            if style == .overlay, #available(iOS 14.0, *), let scene = host.view.window?.windowScene {
                let config = SKOverlay.AppConfiguration(appIdentifier: product.appStoreId, position: .bottom)
                config.campaignToken = product.campaignToken
                config.providerToken = product.providerToken
                if #available(iOS 15.0, *) { config.customProductPageIdentifier = product.customProductPageId }
                SKOverlay(configuration: config).present(in: scene)
                return completion(true)
            }
            var params: [String: Any] = [SKStoreProductParameterITunesItemIdentifier: product.appStoreId]
            if let ct = product.campaignToken { params[SKStoreProductParameterCampaignToken] = ct }
            if let pt = product.providerToken { params[SKStoreProductParameterProviderToken] = pt }
            if #available(iOS 15.0, *), let page = product.customProductPageId {
                params[SKStoreProductParameterCustomProductPageIdentifier] = page
            }
            let store = SKStoreProductViewController()
            store.delegate = self
            host.present(store, animated: true)
            store.loadProduct(withParameters: params) { loaded, _ in
                DispatchQueue.main.async {
                    if !loaded { store.dismiss(animated: true) }
                    completion(loaded)
                }
            }
        }
    }

    public func productViewControllerDidFinish(_ viewController: SKStoreProductViewController) {
        viewController.dismiss(animated: true)
    }
}
#endif
