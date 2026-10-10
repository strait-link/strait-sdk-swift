import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// The clipboard, behind one protocol so the SDK's use of it is testable
/// (contract B19). The SDK calls it ONLY when the workspace turned the paste
/// handoff on (read live from the engine's `/v1/match` reply, Dashboard Settings
/// -> iPhone installs) and device matching found nothing, only on the
/// once-per-install deferred check, and only on iOS.
public protocol StraitPasteboard {
    /// Whether the clipboard probably holds a web URL, WITHOUT reading it:
    /// iOS shows no paste prompt for this (`UIPasteboard.detectPatterns`).
    func hasProbableWebURL(completion: @escaping (Bool) -> Void)
    /// Reads the clipboard text. On iOS this shows the system "Allow Paste" prompt.
    func readString() -> String?
}

/// The real clipboard: `UIPasteboard.general`. Without UIKit (macOS, tests) or
/// below iOS 15 it reports no URL and reads nothing.
public struct SystemPasteboard: StraitPasteboard {
    public init() {}

    public func hasProbableWebURL(completion: @escaping (Bool) -> Void) {
        #if canImport(UIKit) && !os(watchOS) && !os(tvOS)
        if #available(iOS 15.0, *) {
            UIPasteboard.general.detectPatterns(for: [UIPasteboard.DetectionPattern.probableWebURL]) { result in
                switch result {
                case let .success(found): completion(found.contains(UIPasteboard.DetectionPattern.probableWebURL))
                case .failure: completion(false)
                }
            }
            return
        }
        #endif
        completion(false)
    }

    public func readString() -> String? {
        #if canImport(UIKit) && !os(watchOS) && !os(tvOS)
        return UIPasteboard.general.string
        #else
        return nil
        #endif
    }
}

#if os(iOS)
/// Apple's system Paste button (`UIPasteControl`, iOS 16+) wired to the clipboard
/// boost (B19): the person's tap is the consent, so iOS shows NO paste prompt.
/// Show it on first launch (for example when `StraitLinks.handoffAvailable`
/// says a URL is on the clipboard); a pasted Strait handoff link is claimed via
/// `StraitLinks.claimHandoff(text:)` and the result arrives on `onLink` (and `onResult`).
///
/// By default it is drawn in the Strait design system (v5): the orange fill `#FF6A13` with ink
/// text `#0F0D0A` (6.8:1) in light and dark, 8 pt corners, icon and label, at least 44 pt tall.
/// Pass your own `UIPasteControl.Configuration` to match your app instead.
@available(iOS 16.0, *)
public final class StraitPasteButton: UIView {
    public let straitLinks: StraitLinks
    /// Called with the claim's `LinkEvent` (matched or not).
    public var onResult: ((LinkEvent) -> Void)?
    public let control: UIPasteControl

    /// The Strait look for Apple's Paste control (design system v5): brand fill, on-brand
    /// text, `Radius.md` corners, icon and label. The colours follow light / dark.
    public static func straitConfiguration() -> UIPasteControl.Configuration {
        let c = UIPasteControl.Configuration()
        c.displayMode = .iconAndLabel
        c.cornerStyle = .fixed
        c.cornerRadius = CGFloat(StraitTokens.Radius.md)
        c.baseBackgroundColor = StraitTokens.dynamic(\.brand)
        c.baseForegroundColor = StraitTokens.dynamic(\.onBrand)
        return c
    }

    public init(straitLinks: StraitLinks, configuration: UIPasteControl.Configuration = StraitPasteButton.straitConfiguration()) {
        self.straitLinks = straitLinks
        self.control = UIPasteControl(configuration: configuration)
        super.init(frame: .zero)
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.url.identifier, UTType.plainText.identifier])
        control.target = self
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.topAnchor.constraint(equalTo: topAnchor),
            control.bottomAnchor.constraint(equalTo: bottomAnchor),
            // A 44 pt touch target (WCAG 2.5.8, Apple HIG).
            control.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func paste(itemProviders: [NSItemProvider]) {
        straitLinks.claimHandoff(itemProviders: itemProviders) { [weak self] e in self?.onResult?(e) }
    }

    public override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool { true }
}
#endif
