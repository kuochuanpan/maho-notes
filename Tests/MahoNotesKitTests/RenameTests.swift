import Testing
import Foundation
@testable import MahoNotesKit

@Suite("Rename & Icon")
struct RenameTests {
    private func makeTestVault() throws -> (Vault, URL) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("test-vault-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let yaml = """
        author:
          name: ""
        collections:
          - id: notes
            name: My Notes
            icon: star
            description: ""
        """
        try yaml.write(to: tmp.appendingPathComponent("maho.yaml"), atomically: true, encoding: .utf8)

        let collDir = tmp.appendingPathComponent("notes")
        try fm.createDirectory(at: collDir, withIntermediateDirectories: true)

        return (Vault(path: tmp.path), tmp)
    }

    @Test func renameNoteTitle() throws {
        let (vault, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let relPath = try vault.createNote(title: "Original Title", collection: "notes", tags: [])
        vault.renameNote(relativePath: relPath, newTitle: "New Title")

        let note = try vault.showNote(relativePath: relPath)
        #expect(note?.title == "New Title")
    }

    @Test func renameTopLevelCollection() throws {
        let (_, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try updateCollectionInConfig(vaultPath: tmp.path, id: "notes", name: "Renamed Notes")

        let collections = try loadCollections(from: tmp.path)
        #expect(collections.first(where: { $0.id == "notes" })?.name == "Renamed Notes")
    }

    @Test func changeTopLevelCollectionIcon() throws {
        let (_, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try updateCollectionInConfig(vaultPath: tmp.path, id: "notes", icon: "heart")

        let collections = try loadCollections(from: tmp.path)
        #expect(collections.first(where: { $0.id == "notes" })?.icon == "heart")
    }

    @Test func renameSubCollection() throws {
        let (vault, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fm = FileManager.default
        let subDir = tmp.appendingPathComponent("notes/drafts")
        try fm.createDirectory(at: subDir, withIntermediateDirectories: true)

        try vault.renameSubCollection(collectionId: "notes/drafts", newName: "My Drafts")

        // Verify _index.md was created/updated with the new title
        let indexContent = try String(contentsOfFile: subDir.appendingPathComponent("_index.md").path, encoding: .utf8)
        #expect(indexContent.contains("title: My Drafts"))
    }

    @Test func renameSubCollectionWithExistingIndex() throws {
        let (vault, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fm = FileManager.default
        let subDir = tmp.appendingPathComponent("notes/drafts")
        try fm.createDirectory(at: subDir, withIntermediateDirectories: true)

        // Create existing _index.md with title and order
        let existingIndex = "---\ntitle: Old Name\norder:\n  - a.md\n  - b.md\n---\n"
        try existingIndex.write(toFile: subDir.appendingPathComponent("_index.md").path, atomically: true, encoding: .utf8)

        try vault.renameSubCollection(collectionId: "notes/drafts", newName: "New Name")

        let indexContent = try String(contentsOfFile: subDir.appendingPathComponent("_index.md").path, encoding: .utf8)
        #expect(indexContent.contains("title: New Name"))
        // Order should be preserved
        #expect(indexContent.contains("a.md"))
    }

    @Test func updateCollectionNameOnly() throws {
        let (_, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Only update name, icon should remain "star"
        try updateCollectionInConfig(vaultPath: tmp.path, id: "notes", name: "Updated Name")

        let collections = try loadCollections(from: tmp.path)
        let coll = collections.first(where: { $0.id == "notes" })
        #expect(coll?.name == "Updated Name")
        #expect(coll?.icon == "star")
    }

    @Test func updateCollectionIconOnly() throws {
        let (_, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Only update icon, name should remain "My Notes"
        try updateCollectionInConfig(vaultPath: tmp.path, id: "notes", icon: "globe")

        let collections = try loadCollections(from: tmp.path)
        let coll = collections.first(where: { $0.id == "notes" })
        #expect(coll?.name == "My Notes")
        #expect(coll?.icon == "globe")
    }
}
