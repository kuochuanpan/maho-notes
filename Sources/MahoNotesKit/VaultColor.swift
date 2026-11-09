import Foundation

/// A named badge color for a vault, from the palette shown in the app's color picker.
///
/// The registry stores only the `name` (`VaultEntry.color`); the RGB value lives here so every
/// platform renders a name the same way. Names are stable identifiers — the 18 names older
/// builds offered (`red`, `orange`, … `charcoal`) are kept, with their values redrawn to suit the
/// NTHU plum theme, so an older build on another device still shows a vault in a similar hue.
public struct VaultColor: Sendable, Hashable, Identifiable {
    /// Identifier stored in `vaults.yaml`.
    public let name: String
    /// sRGB value as `0xRRGGBB`.
    public let rgb: UInt32

    public var id: String { name }

    public init(name: String, rgb: UInt32) {
        self.name = name
        self.rgb = rgb
    }

    /// Red component, 0…1.
    public var red: Double { Double((rgb >> 16) & 0xFF) / 255 }
    /// Green component, 0…1.
    public var green: Double { Double((rgb >> 8) & 0xFF) / 255 }
    /// Blue component, 0…1.
    public var blue: Double { Double(rgb & 0xFF) / 255 }

    /// `#RRGGBB`.
    public var hexString: String { String(format: "#%06X", rgb) }
}

extension VaultColor {
    /// The palette, in picker order: three rows of hues around the color wheel and a row of
    /// muted tones (six per row, matching the picker grids).
    ///
    /// Every color comes from one family in OKLCH (lightness about 0.45–0.66, moderate chroma),
    /// so badges read as a set against the plum vault rail (`#721F6D`). Each one keeps the white
    /// badge letter at 3:1 contrast or better (WCAG large text), and stays visibly apart from the
    /// rail itself.
    public static let palette: [VaultColor] = [
        VaultColor(name: "red", rgb: 0xBC4945),
        VaultColor(name: "coral", rgb: 0xCF745C),
        VaultColor(name: "orange", rgb: 0xC17429),
        VaultColor(name: "yellow", rgb: 0xAF8C28),
        VaultColor(name: "olive", rgb: 0x70843C),
        VaultColor(name: "green", rgb: 0x3D8A56),

        VaultColor(name: "forest", rgb: 0x275F49),
        VaultColor(name: "mint", rgb: 0x469D87),
        VaultColor(name: "teal", rgb: 0x2A8082),
        VaultColor(name: "cyan", rgb: 0x3D8EAC),
        VaultColor(name: "sky", rgb: 0x6092C2),
        VaultColor(name: "blue", rgb: 0x3E66B3),

        VaultColor(name: "indigo", rgb: 0x514A9D),
        VaultColor(name: "lavender", rgb: 0x9982BD),
        VaultColor(name: "purple", rgb: 0x884DA9),
        VaultColor(name: "orchid", rgb: 0xB460A5),
        VaultColor(name: "pink", rgb: 0xCE648C),
        VaultColor(name: "berry", rgb: 0x982F49),

        VaultColor(name: "brown", rgb: 0x7E5A42),
        VaultColor(name: "sand", rgb: 0x9F8A6B),
        VaultColor(name: "sage", rgb: 0x71886C),
        VaultColor(name: "slate", rgb: 0x5F7182),
        VaultColor(name: "mauve", rgb: 0x866A83),
        VaultColor(name: "charcoal", rgb: 0x414248),
    ]

    /// The order in which vaults without a color are given one. Neighbors alternate warm and
    /// cool so consecutive vaults look different, and the colors closest to the plum rail
    /// (purple, indigo, berry, mauve) and the dark neutrals come last.
    public static let assignmentOrder: [String] = [
        "teal", "coral", "sky", "yellow", "orchid", "green",
        "blue", "orange", "lavender", "olive", "pink", "cyan",
        "indigo", "sage", "red", "mint", "purple", "sand",
        "slate", "berry", "forest", "brown", "mauve", "charcoal",
    ]

    private static let byName: [String: VaultColor] =
        Dictionary(uniqueKeysWithValues: palette.map { ($0.name, $0) })

    /// The palette color with this name, or `nil` for a missing, empty or unknown name.
    public static func named(_ name: String?) -> VaultColor? {
        guard let name else { return nil }
        return byName[name]
    }

    /// The color a new vault gets: the one used by the fewest existing vaults, earliest in
    /// `assignmentOrder` on a tie. Every vault gets its own color until the palette runs out.
    public static func nextForNewVault(among existing: [VaultEntry]) -> VaultColor {
        var usage: [String: Int] = [:]
        for entry in existing {
            if let color = named(entry.color) { usage[color.name, default: 0] += 1 }
        }
        // `min(by:)` returns the first of equal elements, so ties go to the earlier name.
        let name = assignmentOrder.min { usage[$0, default: 0] < usage[$1, default: 0] }!
        return byName[name]!
    }

    /// The color to draw for a vault: its stored color, or — for a vault with none, or a name
    /// from a newer palette — a color picked from the vault name, the same on every device.
    public static func resolved(for entry: VaultEntry) -> VaultColor {
        named(entry.color) ?? fallback(forVaultNamed: entry.name)
    }

    /// A color derived from the vault name with FNV-1a, which (unlike `hashValue`) gives the
    /// same result in every process.
    static func fallback(forVaultNamed name: String) -> VaultColor {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return byName[assignmentOrder[Int(hash % UInt64(assignmentOrder.count))]]!
    }
}

extension VaultRegistry {
    /// Gives every vault that has no color one from the palette (see
    /// `VaultColor.nextForNewVault(among:)`), in registry order.
    ///
    /// A color name this build doesn't know is left alone — it may come from a newer build
    /// sharing the registry through iCloud.
    /// - Returns: `true` if any vault was given a color.
    @discardableResult
    public mutating func assignMissingVaultColors() -> Bool {
        var changed = false
        for index in vaults.indices where (vaults[index].color ?? "").isEmpty {
            vaults[index].color = VaultColor.nextForNewVault(among: vaults).name
            changed = true
        }
        return changed
    }
}
