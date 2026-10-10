import StraitSDK
import SwiftUI
import UIKit

// The reference app in the Strait design system (v5), from the SDK's generated StraitTokens:
// warm grounds and surfaces instead of the system's cool greys, orange words in brand-text
// (#B84200 light, #FF8237 dark; AA on every ground), the orange fill only for the one primary
// action, system fonts, no motion of our own. Light and dark follow the phone's setting.

extension Color {
    /// A token colour that follows light / dark, e.g. `Color.strait(\.textMuted)`.
    static func strait(_ role: KeyPath<StraitColors, StraitColor>) -> Color {
        Color(uiColor: StraitTokens.dynamic(role))
    }
}

enum StraitTheme {
    /// Navigation and tab bars on the warm surfaces, with brand-text for the selected tab.
    static func applyAppearance() {
        // Titles in ink; the bar itself stays the system's material so it works with any ground.
        UINavigationBar.appearance().largeTitleTextAttributes = [.foregroundColor: StraitTokens.dynamic(\.text)]
        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: StraitTokens.dynamic(\.text)]

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = StraitTokens.dynamic(\.surface)
        tab.shadowColor = StraitTokens.dynamic(\.border)
        for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            item.normal.iconColor = StraitTokens.dynamic(\.textSubtle)
            item.normal.titleTextAttributes = [.foregroundColor: StraitTokens.dynamic(\.textSubtle)]
            item.selected.iconColor = StraitTokens.dynamic(\.brandText)
            item.selected.titleTextAttributes = [.foregroundColor: StraitTokens.dynamic(\.brandText)]
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
}

extension View {
    /// A List or Form screen: the warm ground behind it and brand-text for buttons and links.
    func straitScreen() -> some View {
        scrollContentBackground(.hidden)
            .background(Color.strait(\.bgSubtle).ignoresSafeArea())
            .tint(Color.strait(\.brandText))
    }

    /// Rows on the card surface (apply to a Section).
    func straitRows() -> some View {
        listRowBackground(Color.strait(\.surface))
    }
}

/// The one primary action on a screen: orange fill, ink text (6.8:1), 8 pt corners, 44 pt tall.
struct StraitPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundColor(Color.strait(\.onBrand))
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: StraitTokens.Radius.md)
                    .fill(Color.strait(configuration.isPressed ? \.brandPress : \.brand))
            )
    }
}

/// A List / Form section header in the warm text-muted token. The system's default
/// (secondaryLabel) is a cool lavender grey in dark mode, which the design system rules out.
struct StraitHeader: View {
    private let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).foregroundColor(Color.strait(\.textMuted)) }
}

/// A List / Form section footer in the warm text-muted token (AA on bg-subtle in both themes).
struct StraitFooter: View {
    private let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).foregroundColor(Color.strait(\.textMuted)) }
}
