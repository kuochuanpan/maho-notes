import SwiftUI

/// Centralized color theme for Maho Notes using NTHU purple as the brand color.
enum MahoTheme {
    // MARK: - A Column (Vault Rail + Title Bar)

    /// #7F1084 — NTHU Seance purple, same for both modes.
    static let vaultRailBackground = Color(red: 127 / 255, green: 16 / 255, blue: 132 / 255)

    /// White text/icons on the purple background.
    static let vaultRailForeground = Color.white

    // MARK: - B Column (Navigator)

    /// Dark: deep purple-black #2A0A2E, Light: pale lavender #F3E6F5.
    static func navigatorBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 42 / 255, green: 10 / 255, blue: 46 / 255)
            : Color(red: 243 / 255, green: 230 / 255, blue: 245 / 255)
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
