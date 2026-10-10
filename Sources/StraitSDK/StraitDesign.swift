import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit

// UIKit helpers for the generated design tokens (StraitTokens.swift, Strait design system v5).
// StraitTokens.swift is copied from the brand repo (brand/tokens/platforms/ios) and never edited
// by hand; this file only bridges it to UIKit.

public extension StraitColor {
    /// This colour as a `UIColor` (sRGB).
    var uiColor: UIColor {
        UIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
}

public extension StraitTokens {
    /// A colour that follows the system light / dark setting, e.g. `StraitTokens.dynamic(\.brand)`.
    static func dynamic(_ role: KeyPath<StraitColors, StraitColor>) -> UIColor {
        UIColor { traits in
            (traits.userInterfaceStyle == .dark ? StraitTokens.dark : StraitTokens.light)[keyPath: role].uiColor
        }
    }
}
#endif
