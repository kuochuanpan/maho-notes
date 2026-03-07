import SwiftUI

/// Centralized color theme for Maho Notes using NTHU purple as the brand color.
enum MahoTheme {
    // MARK: - A Column (Vault Rail + Title Bar)

    /// #721F6D — NTHU Plum purple (deeper), same for both modes.
    static let vaultRailBackground = Color(red: 114 / 255, green: 31 / 255, blue: 109 / 255)

    /// White text/icons on the purple background.
    static let vaultRailForeground = Color.white

    // MARK: - B Column (Navigator)

    /// Dark: #7F1084 (NTHU Seance purple, brighter than A), Light: #F3E6F5 (pale lavender).
    static func navigatorBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 127 / 255, green: 16 / 255, blue: 132 / 255)
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
