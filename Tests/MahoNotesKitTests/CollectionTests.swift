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
        try yaml.write(to: tmp.appendingPathComponent("collections.yaml"), atomically: true, encoding: .utf8)

        let collections = try loadCollections(from: tmp.path)
        #expect(collections.count == 2)
        #expect(collections[0].id == "japanese")
        #expect(collections[0].name == "日本語")
        #expect(collections[0].icon == "character.book.closed")
        #expect(collections[1].id == "astronomy")

        try fm.removeItem(at: tmp)
    }

    @Test func loadEmptyCollections() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("test-vault-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let yaml = "collections: []\n"
        try yaml.write(to: tmp.appendingPathComponent("collections.yaml"), atomically: true, encoding: .utf8)

        let collections = try loadCollections(from: tmp.path)
        #expect(collections.isEmpty)

        try fm.removeItem(at: tmp)
    }
}
