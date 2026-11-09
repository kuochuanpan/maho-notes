import SwiftUI
import MahoNotesKit

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

    // MARK: - Vault Colors

    // The palette itself lives in MahoNotesKit (`VaultColor.palette`), so the registry code that
    // gives new vaults a color and the views that draw it agree on the names.

    struct VaultColorOption: Identifiable {
        let name: String
        let color: Color
        var id: String { name }
    }

    /// Picker swatches, in palette order (four rows of six).
    static let vaultColorOptions: [VaultColorOption] = VaultColor.palette.map {
        VaultColorOption(name: $0.name, color: color(for: $0))
    }

    /// Badge color for a vault: its stored palette color, or a name-derived palette color
    /// for a vault that has none yet.
    static func resolvedVaultColor(for entry: VaultEntry) -> Color {
        color(for: VaultColor.resolved(for: entry))
    }

    private static func color(for vaultColor: VaultColor) -> Color {
        Color(.sRGB, red: vaultColor.red, green: vaultColor.green, blue: vaultColor.blue)
    }

    // MARK: - C Column (Note Content)

    /// Dark: #1E1E1E (macOS-matching dark gray), Light: system background.
    /// Prevents pure-black on iPad NavigationSplitView detail column.
    static func contentBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255)
            : Color(red: 1.0, green: 1.0, blue: 1.0)
    }
}
