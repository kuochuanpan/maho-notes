import Foundation
import Yams

/// A collection definition from collections.yaml
public struct Collection: Sendable, Codable {
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

/// Parses collections.yaml from the vault root
public func loadCollections(from vaultPath: String) throws -> [Collection] {
    let url = URL(fileURLWithPath: vaultPath).appendingPathComponent("collections.yaml")
    let data = try String(contentsOf: url, encoding: .utf8)

    guard let yaml = try Yams.load(yaml: data) as? [String: Any],
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
