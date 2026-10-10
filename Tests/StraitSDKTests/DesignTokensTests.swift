import XCTest
@testable import StraitSDK
#if canImport(UIKit)
import UIKit
#endif

/// The generated design tokens (StraitTokens.swift, design system v5) keep the rules the
/// Strait UI in this SDK depends on: one orange accent, warm neutrals, AA contrast.
final class DesignTokensTests: XCTestCase {
    private func luminance(_ c: StraitColor) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.red) + 0.7152 * lin(c.green) + 0.0722 * lin(c.blue)
    }

    private func contrast(_ a: StraitColor, _ b: StraitColor) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private func hue(_ c: StraitColor) -> Double? {
        let mx = max(c.red, c.green, c.blue), mn = min(c.red, c.green, c.blue), d = mx - mn
        if d < 0.004 { return nil } // white, black
        var h: Double
        if mx == c.red { h = ((c.green - c.blue) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == c.green { h = (c.blue - c.red) / d + 2 }
        else { h = (c.red - c.green) / d + 4 }
        h *= 60
        return h < 0 ? h + 360 : h
    }

    func testVersionAndBrand() {
        XCTAssertTrue(StraitTokens.version.hasPrefix("5."))
        for t in [StraitTokens.light, StraitTokens.dark] {
            XCTAssertEqual(t.brand.rgb, 0xFF6A13)
            XCTAssertEqual(t.onBrand.rgb, 0x0F0D0A)
        }
    }

    func testPasteButtonColoursMeetAA() {
        for t in [StraitTokens.light, StraitTokens.dark] {
            XCTAssertGreaterThanOrEqual(contrast(t.brand, t.onBrand), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(t.text, t.bg), 4.5)
            XCTAssertGreaterThanOrEqual(contrast(t.textMuted, t.surface), 4.5)
        }
    }

    /// DS v5 §3.4: no blue, teal, violet, pink or cool grey; red / amber / green only on status roles.
    func testNoForbiddenHues() {
        let statusWords = ["status", "success", "warning", "danger", "Failed", "failed"]
        for (theme, t) in [("light", StraitTokens.light), ("dark", StraitTokens.dark)] {
            for child in Mirror(reflecting: t).children {
                guard let name = child.label, let c = child.value as? StraitColor, let h = hue(c) else { continue }
                let isStatus = statusWords.contains { name.contains($0) }
                let warm = (10...60).contains(h)
                let statusHue = h <= 12 || (30...50).contains(h) || (80...140).contains(h)
                XCTAssertTrue(warm || (isStatus && statusHue), "\(theme).\(name) hue \(Int(h))")
            }
        }
    }

    #if os(iOS)
    func testDynamicColourFollowsTheme() {
        let c = StraitTokens.dynamic(\.surface)
        let dark = c.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        let light = c.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        XCTAssertNotEqual(dark, light)
    }

    @available(iOS 16.0, *)
    func testPasteButtonUsesStraitConfiguration() {
        let c = StraitPasteButton.straitConfiguration()
        XCTAssertEqual(c.displayMode, .iconAndLabel)
        XCTAssertEqual(c.cornerRadius, 8)
        let fill = c.baseBackgroundColor!.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        fill.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(Int((r * 255).rounded()), 0xFF)
        XCTAssertEqual(Int((g * 255).rounded()), 0x6A)
        XCTAssertEqual(Int((b * 255).rounded()), 0x13)
    }
    #endif
}
