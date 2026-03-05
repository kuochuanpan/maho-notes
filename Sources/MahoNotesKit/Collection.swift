import Foundation
import Yams

/// A collection definition from maho.yaml
public struct Collection: Sendable, Codable, Hashable {
    public let id: String
    public let name: String
    public let icon: String
    public let description: String

    public init(id: String, name: String, icon: String, description: String) {
        self.id = id
        self.name = name
        self.icon = icon
        self.description = description
    }

    /// Emoji fallback for CLI display (SF Symbols can't render in terminal)
    public var cliIcon: String {
        Self.sfSymbolToEmoji[icon] ?? "📁"
    }

    private static let sfSymbolToEmoji: [String: String] = [
        "character.book.closed": "📖",
        "sparkles": "✨",
        "terminal": "💻",
        "wrench.and.screwdriver": "🔧",
        "questionmark.circle": "❓",
        "book.closed": "📕",
        "star": "⭐",
        "folder": "📁",
        "doc.text": "📄",
        "globe": "🌐",
        "music.note": "🎵",
        "photo": "🖼️",
        "gamecontroller": "🎮",
        "heart": "❤️",
        "lightbulb": "💡",
        "graduationcap": "🎓",
        "flask": "🧪",
        "atom": "⚛️",
    ]
}

/// Parses the collections: key from maho.yaml in the vault root.
/// If collections.yaml exists but maho.yaml lacks a collections: key, migrates
/// the collections into maho.yaml and deletes collections.yaml.
public func loadCollections(from vaultPath: String) throws -> [Collection] {
    let fm = FileManager.default
    let mahoURL = URL(fileURLWithPath: vaultPath).appendingPathComponent("maho.yaml")
    let legacyURL = URL(fileURLWithPath: vaultPath).appendingPathComponent("collections.yaml")

    // Migration: collections.yaml exists but maho.yaml has no collections: key
    if fm.fileExists(atPath: legacyURL.path) {
        let mahoContent = (try? String(contentsOf: mahoURL, encoding: .utf8)) ?? ""
        if !mahoContent.contains("collections:") {
            let legacyContent = try String(contentsOf: legacyURL, encoding: .utf8)
            let separator = mahoContent.hasSuffix("\n") ? "" : "\n"
            let merged = mahoContent + separator + legacyContent
            try merged.write(to: mahoURL, atomically: true, encoding: .utf8)
            try fm.removeItem(at: legacyURL)
            print("Migrated collections from collections.yaml → maho.yaml")
        }
    }

    guard let data = try? String(contentsOf: mahoURL, encoding: .utf8),
          let yaml = try? Yams.load(yaml: data) as? [String: Any],
          let items = yaml["collections"] as? [[String: Any]]
    else {
        return []
    }

    return items.compactMap { item in
        guard let id = item["id"] as? String,
              let name = item["name"] as? String
        else { return nil }
        return Collection(
            id: id,
            name: name,
            icon: item["icon"] as? String ?? "",
            description: item["description"] as? String ?? ""
        )
    }
}
