import SwiftUI

/// Centralized color theme for Maho Notes using NTHU purple as the brand color.
enum MahoTheme {
    // MARK: - A Column (Vault Rail + Title Bar)

    /// #721F6D — NTHU Plum purple (deeper), same for both modes.
    static let vaultRailBackground = Color(red: 114 / 255, green: 31 / 255, blue: 109 / 255)

    /// White text/icons on the purple background.
    static let vaultRailForeground = Color.white

    // MARK: - Accent

    /// App-wide accent purple — used for selection highlight, tint, interactive elements.
    /// Light: #721F6D (same as vault rail), Dark: #8B3787 (brighter for contrast).
    static func accent(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 139 / 255, green: 55 / 255, blue: 135 / 255)
            : vaultRailBackground
    }

    // MARK: - B Column (Navigator)

    /// Dark: #4A1050 (deeper purple than A), Light: #E0CCE6 (muted lavender).
    static func navigatorBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 74 / 255, green: 16 / 255, blue: 80 / 255)
            : Color(red: 224 / 255, green: 204 / 255, blue: 230 / 255)
    }

    /// Dark: white, Light: primary (system default).
    static func navigatorForeground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white : .primary
    }

    /// Dark: white 70%, Light: secondary.
    static func navigatorSecondaryForeground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white.opacity(0.7) : .secondary
    }
}
