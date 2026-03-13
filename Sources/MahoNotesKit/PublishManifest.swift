import Foundation
import CryptoKit

/// Tracks published note state for incremental site generation
public struct PublishManifest: Sendable, Codable {
    public var entries: [String: ManifestEntry]  // key = note relativePath

    public struct ManifestEntry: Sendable, Codable {
        public let contentHash: String  // SHA-256 of frontmatter+body
        public let slug: String
        public let collection: String
        public let generatedAt: String  // ISO8601

        public init(contentHash: String, slug: String, collection: String, generatedAt: String) {
            self.contentHash = contentHash
            self.slug = slug
            self.collection = collection
            self.generatedAt = generatedAt
        }
    }

    public init(entries: [String: ManifestEntry] = [:]) {
        self.entries = entries
    }

    // MARK: - Persistence

    private static let manifestDir = ".maho"
    private static let manifestFile = "publish-manifest.json"

    /// Load from .maho/publish-manifest.json
    public static func load(from vaultPath: String) throws -> PublishManifest {
        let path = (vaultPath as NSString)
            .appendingPathComponent(manifestDir)
            .appending("/\(manifestFile)")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(PublishManifest.self, from: data)
    }

    /// Save to .maho/publish-manifest.json
    public func save(to vaultPath: String) throws {
        let dir = (vaultPath as NSString).appendingPathComponent(Self.manifestDir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent(Self.manifestFile)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Compute SHA-256 hash of note content (frontmatter + body combined via relativePath file)
    public static func contentHash(for note: Note) -> String {
        // Hash the full content that affects output: title, body, tags, public, draft, slug, author, order, series, updated
        let material = "\(note.title)\n\(note.body)\n\(note.tags.joined(separator: ","))\n\(note.isPublic)\n\(note.draft)\n\(note.slug ?? "")\n\(note.author ?? "")\n\(note.updated)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
