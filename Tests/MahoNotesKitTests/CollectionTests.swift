import Testing
import Foundation
@testable import MahoNotesKit

@Suite("Collection loading")
struct CollectionTests {
    @Test func loadValidCollections() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("test-vault-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let yaml = """
        author:
          name: ""
        collections:
          - id: japanese
            name: 日本語
            icon: character.book.closed
            description: Japanese notes
          - id: astronomy
            name: 天文
            icon: sparkles
            description: Astronomy notes
        """
        try yaml.write(to: tmp.appendingPathComponent("maho.yaml"), atomically: true, encoding: .utf8)

        let collections = try loadCollections(from: tmp.path)
        #expect(collections.count == 2)
        #expect(collections[0].id == "japanese")
        #expect(collections[0].name == "日本語")
        #expect(collections[0].icon == "character.book.closed")
        #expect(collections[1].id == "astronomy")

        try fm.removeItem(at: tmp)
    }

    @Test func migratesCollectionsYamlIntoMahoYaml() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("test-vault-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // maho.yaml exists but has no collections: key
        let mahoYaml = "author:\n  name: \"\"\ngithub:\n  repo: \"\"\n"
        try mahoYaml.write(to: tmp.appendingPathComponent("maho.yaml"), atomically: true, encoding: .utf8)

        // collections.yaml exists with collections
        let legacyYaml = """
        collections:
          - id: migrated
            name: Migrated Collection
            icon: star
            description: Was in collections.yaml
        """
        try legacyYaml.write(to: tmp.appendingPathComponent("collections.yaml"), atomically: true, encoding: .utf8)

        let collections = try loadCollections(from: tmp.path)
        #expect(collections.count == 1)
        #expect(collections[0].id == "migrated")
        #expect(collections[0].name == "Migrated Collection")

        // collections.yaml should be deleted after migration
        #expect(!fm.fileExists(atPath: tmp.appendingPathComponent("collections.yaml").path))

        // maho.yaml should now contain the collections: key
        let updatedMaho = try String(contentsOf: tmp.appendingPathComponent("maho.yaml"), encoding: .utf8)
        #expect(updatedMaho.contains("collections:"))
        #expect(updatedMaho.contains("migrated"))
    }

    @Test func loadEmptyCollections() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("test-vault-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let yaml = "author:\n  name: \"\"\ncollections: []\n"
        try yaml.write(to: tmp.appendingPathComponent("maho.yaml"), atomically: true, encoding: .utf8)

        let collections = try loadCollections(from: tmp.path)
        #expect(collections.isEmpty)

        try fm.removeItem(at: tmp)
    }
}
