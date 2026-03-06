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

/// Add a new collection to the vault's maho.yaml and create its directory.
/// - Parameters:
///   - vaultPath: Absolute path to the vault root.
///   - id: Directory name / collection id (e.g. "my-notes"). Auto-generated from name if nil.
///   - name: Display name (e.g. "My Notes").
///   - icon: SF Symbol name (defaults to "folder").
///   - description: Optional description.
/// - Throws: If maho.yaml can't be read/written or directory creation fails.
public func addCollection(
    vaultPath: String,
    id: String? = nil,
    name: String,
    icon: String = "folder",
    description: String = ""
) throws {
    let collectionId = id ?? makeSlug(from: name)
    guard !collectionId.isEmpty else {
        throw CollectionError.invalidName
    }

    let fm = FileManager.default
    let mahoURL = URL(fileURLWithPath: vaultPath).appendingPathComponent("maho.yaml")

    // Load existing maho.yaml
    var yaml: [String: Any] = [:]
    if let content = try? String(contentsOf: mahoURL, encoding: .utf8),
       let loaded = try? Yams.load(yaml: content) as? [String: Any] {
        yaml = loaded
    }

    // Get existing collections array
    var collections = yaml["collections"] as? [[String: Any]] ?? []

    // Check for duplicate id
    if collections.contains(where: { ($0["id"] as? String) == collectionId }) {
        throw CollectionError.alreadyExists(collectionId)
    }

    // Add new collection entry
    var entry: [String: Any] = [
        "id": collectionId,
        "name": name,
    ]
    if !icon.isEmpty && icon != "folder" {
        entry["icon"] = icon
    }
    if !description.isEmpty {
        entry["description"] = description
    }
    collections.append(entry)
    yaml["collections"] = collections

    // Write back maho.yaml
    let output = try Yams.dump(object: yaml)
    try output.write(to: mahoURL, atomically: true, encoding: .utf8)

    // Create the collection directory
    let collectionDir = (vaultPath as NSString).appendingPathComponent(collectionId)
    if !fm.fileExists(atPath: collectionDir) {
        try fm.createDirectory(atPath: collectionDir, withIntermediateDirectories: true)
    }
}

/// Reorder collections in maho.yaml to match the given id order.
/// Any ids not in `orderedIds` are appended at the end.
public func reorderCollections(vaultPath: String, orderedIds: [String]) throws {
    let mahoURL = URL(fileURLWithPath: vaultPath).appendingPathComponent("maho.yaml")

    guard let content = try? String(contentsOf: mahoURL, encoding: .utf8),
          var yaml = try? Yams.load(yaml: content) as? [String: Any],
          let items = yaml["collections"] as? [[String: Any]]
    else { return }

    let itemMap = Dictionary(items.compactMap { item -> (String, [String: Any])? in
        guard let id = item["id"] as? String else { return nil }
        return (id, item)
    }, uniquingKeysWith: { first, _ in first })

    // Ordered items first, then any remaining
    var reordered: [[String: Any]] = orderedIds.compactMap { itemMap[$0] }
    let remaining = items.filter { item in
        guard let id = item["id"] as? String else { return true }
        return !orderedIds.contains(id)
    }
    reordered.append(contentsOf: remaining)

    yaml["collections"] = reordered
    let output = try Yams.dump(object: yaml)
    try output.write(to: mahoURL, atomically: true, encoding: .utf8)
}

public enum CollectionError: Error, LocalizedError {
    case invalidName
    case alreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "Collection name is invalid."
        case .alreadyExists(let id): return "Collection '\(id)' already exists."
        }
    }
}
