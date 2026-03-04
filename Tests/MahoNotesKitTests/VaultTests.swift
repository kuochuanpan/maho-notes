import Testing
import Foundation
@testable import MahoNotesKit

@Suite("Vault CRUD")
struct VaultTests {
    private func makeTestVault() throws -> (Vault, URL) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("test-vault-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        // Create collections.yaml
        let collectionsYaml = """
        collections:
          - id: testcoll
            name: Test Collection
            icon: star
            description: A test collection
        """
        try collectionsYaml.write(to: tmp.appendingPathComponent("collections.yaml"), atomically: true, encoding: .utf8)

        // Create collection directory
        let collDir = tmp.appendingPathComponent("testcoll")
        try fm.createDirectory(at: collDir, withIntermediateDirectories: true)

        return (Vault(path: tmp.path), tmp)
    }

    @Test func loadCollections() throws {
        let (vault, tmp) = try makeTestVault()
        let collections = try vault.collections()
        #expect(collections.count == 1)
        #expect(collections[0].id == "testcoll")
        #expect(collections[0].name == "Test Collection")
        try FileManager.default.removeItem(at: tmp)
    }

    @Test func createAndListNote() throws {
        let (vault, tmp) = try makeTestVault()

        let relPath = try vault.createNote(
            title: "My Test Note",
            collection: "testcoll",
            tags: ["tag1", "tag2"],
            author: "tester"
        )

        #expect(relPath.hasPrefix("testcoll/"))
        #expect(relPath.hasSuffix(".md"))
        #expect(relPath.contains("my-test-note"))

        let notes = try vault.allNotes()
        #expect(notes.count == 1)
        #expect(notes[0].title == "My Test Note")
        #expect(notes[0].collection == "testcoll")
        #expect(notes[0].tags == ["tag1", "tag2"])
        #expect(notes[0].author == "tester")

        try FileManager.default.removeItem(at: tmp)
    }

    @Test func showNote() throws {
        let (vault, tmp) = try makeTestVault()

        let relPath = try vault.createNote(
            title: "Show Me",
            collection: "testcoll",
            tags: []
        )

        let note = try vault.showNote(relativePath: relPath)
        #expect(note != nil)
        #expect(note!.title == "Show Me")

        let missing = try vault.showNote(relativePath: "nonexistent.md")
        #expect(missing == nil)

        try FileManager.default.removeItem(at: tmp)
    }

    @Test func searchNotes() throws {
        let (vault, tmp) = try makeTestVault()

        _ = try vault.createNote(title: "Alpha Note", collection: "testcoll", tags: ["findme"])
        _ = try vault.createNote(title: "Beta Note", collection: "testcoll", tags: [])

        let results = try vault.searchNotes(query: "alpha")
        #expect(results.count == 1)
        #expect(results[0].title == "Alpha Note")

        let tagResults = try vault.searchNotes(query: "findme")
        #expect(tagResults.count == 1)

        try FileManager.default.removeItem(at: tmp)
    }

    @Test func listNotesFilterByCollection() throws {
        let fm = FileManager.default
        let (vault, tmp) = try makeTestVault()

        // Create second collection
        let collDir2 = tmp.appendingPathComponent("other")
        try fm.createDirectory(at: collDir2, withIntermediateDirectories: true)

        _ = try vault.createNote(title: "In Test", collection: "testcoll", tags: [])
        _ = try vault.createNote(title: "In Other", collection: "other", tags: [])

        let filtered = try vault.listNotes(collection: "testcoll")
        #expect(filtered.count == 1)
        #expect(filtered[0].title == "In Test")

        let all = try vault.listNotes()
        #expect(all.count == 2)

        try fm.removeItem(at: tmp)
    }

    @Test func listNotesFilterByTag() throws {
        let (vault, tmp) = try makeTestVault()

        _ = try vault.createNote(title: "Tagged", collection: "testcoll", tags: ["special"])
        _ = try vault.createNote(title: "Untagged", collection: "testcoll", tags: [])

        let filtered = try vault.listNotes(tag: "special")
        #expect(filtered.count == 1)
        #expect(filtered[0].title == "Tagged")

        try FileManager.default.removeItem(at: tmp)
    }

    @Test func nestedDirectoryCreation() throws {
        let (vault, tmp) = try makeTestVault()

        let relPath = try vault.createNote(
            title: "Nested Note",
            collection: "testcoll/sub/deep",
            tags: []
        )

        #expect(relPath.hasPrefix("testcoll/sub/deep/"))
        let note = try vault.showNote(relativePath: relPath)
        #expect(note != nil)
        #expect(note!.collection == "testcoll")

        try FileManager.default.removeItem(at: tmp)
    }
}
