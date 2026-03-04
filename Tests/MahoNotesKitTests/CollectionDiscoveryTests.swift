import Testing
import Foundation
@testable import MahoNotesKit

@Suite("Collection Discovery")
struct CollectionDiscoveryTests {
    private func makeTestVault() throws -> (Vault, URL) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("test-vault-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        // Create collections.yaml with one defined collection
        let collectionsYaml = """
        collections:
          - id: defined
            name: Defined Collection
            icon: star
            description: A defined collection
        """
        try collectionsYaml.write(to: tmp.appendingPathComponent("collections.yaml"), atomically: true, encoding: .utf8)

        // Create the defined collection directory with a note
        let definedDir = tmp.appendingPathComponent("defined")
        try fm.createDirectory(at: definedDir, withIntermediateDirectories: true)
        try "---\ntitle: Defined Note\ntags: []\ncreated: 2026-01-01\nupdated: 2026-01-01\npublic: false\nauthor: test\n---\n# Note".write(
            to: definedDir.appendingPathComponent("001-note.md"), atomically: true, encoding: .utf8)

        return (Vault(path: tmp.path), tmp)
    }

    @Test func discoversUndeclaredCollection() throws {
        let (vault, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Create an undeclared collection with a note
        let undeclaredDir = tmp.appendingPathComponent("undeclared")
        try FileManager.default.createDirectory(at: undeclaredDir, withIntermediateDirectories: true)
        try "---\ntitle: Stray Note\ntags: []\ncreated: 2026-01-01\nupdated: 2026-01-01\npublic: false\nauthor: test\n---\n# Stray".write(
            to: undeclaredDir.appendingPathComponent("001-stray.md"), atomically: true, encoding: .utf8)

        let collections = try vault.collections()
        let ids = collections.map { $0.id }
        #expect(ids.contains("defined"))
        #expect(ids.contains("undeclared"))
    }

    @Test func undeclaredCollectionUsesDefaultIcon() throws {
        let (vault, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let undeclaredDir = tmp.appendingPathComponent("newcoll")
        try FileManager.default.createDirectory(at: undeclaredDir, withIntermediateDirectories: true)
        try "---\ntitle: A Note\ntags: []\ncreated: 2026-01-01\nupdated: 2026-01-01\npublic: false\nauthor: test\n---\n# Note".write(
            to: undeclaredDir.appendingPathComponent("001-note.md"), atomically: true, encoding: .utf8)

        let collections = try vault.collections()
        let newcoll = collections.first { $0.id == "newcoll" }
        #expect(newcoll != nil)
        #expect(newcoll?.icon == "folder")
        #expect(newcoll?.cliIcon == "📁")
    }

    @Test func undeclaredCollectionReadsIndexMd() throws {
        let (vault, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dir = tmp.appendingPathComponent("withindex")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\ntitle: My Custom Name\ndescription: A fancy collection\n---\n".write(
            to: dir.appendingPathComponent("_index.md"), atomically: true, encoding: .utf8)
        try "---\ntitle: Note\ntags: []\ncreated: 2026-01-01\nupdated: 2026-01-01\npublic: false\nauthor: test\n---\n# Note".write(
            to: dir.appendingPathComponent("001-note.md"), atomically: true, encoding: .utf8)

        let collections = try vault.collections()
        let withindex = collections.first { $0.id == "withindex" }
        #expect(withindex != nil)
        #expect(withindex?.name == "My Custom Name")
        #expect(withindex?.description == "A fancy collection")
    }

    @Test func emptyDirectoryNotDiscovered() throws {
        let (vault, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Empty directory — should NOT appear as collection
        let emptyDir = tmp.appendingPathComponent("emptycoll")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        let collections = try vault.collections()
        let ids = collections.map { $0.id }
        #expect(!ids.contains("emptycoll"))
    }

    @Test func hiddenDirectoryNotDiscovered() throws {
        let (vault, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Hidden directory — should NOT appear
        let hiddenDir = tmp.appendingPathComponent(".hidden")
        try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)
        try "---\ntitle: Hidden\ntags: []\ncreated: 2026-01-01\nupdated: 2026-01-01\npublic: false\nauthor: test\n---\n# Hidden".write(
            to: hiddenDir.appendingPathComponent("001-note.md"), atomically: true, encoding: .utf8)

        let collections = try vault.collections()
        let ids = collections.map { $0.id }
        #expect(!ids.contains(".hidden"))
    }

    @Test func definedCollectionsAppearFirst() throws {
        let (vault, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dir = tmp.appendingPathComponent("aaa-first-alpha")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\ntitle: Note\ntags: []\ncreated: 2026-01-01\nupdated: 2026-01-01\npublic: false\nauthor: test\n---\n# Note".write(
            to: dir.appendingPathComponent("001-note.md"), atomically: true, encoding: .utf8)

        let collections = try vault.collections()
        // Defined collection should come before discovered ones
        #expect(collections[0].id == "defined")
    }
}
