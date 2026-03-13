import Testing
import Foundation
@testable import MahoNotesKit

@Suite("Ordering: _index.md")
struct OrderingTests {
    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ordering-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    // MARK: - readDirectoryOrder

    @Test func readDirectoryOrder_noIndexFile_returnsEmpty() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let (notes, children) = readDirectoryOrder(at: tmp.path)
        #expect(notes.isEmpty)
        #expect(children.isEmpty)
    }

    @Test func readDirectoryOrder_withOrderAndChildren() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let content = """
        ---
        title: My Collection
        order:
          - first.md
          - second.md
        children:
          - sub-a
          - sub-b
        ---
        Some body content.
        """
        try content.write(to: tmp.appendingPathComponent("_index.md"), atomically: true, encoding: .utf8)

        let (notes, children) = readDirectoryOrder(at: tmp.path)
        #expect(notes == ["first.md", "second.md"])
        #expect(children == ["sub-a", "sub-b"])
    }

    @Test func readDirectoryOrder_noOrderField_returnsEmpty() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let content = """
        ---
        title: No Order
        ---
        Body.
        """
        try content.write(to: tmp.appendingPathComponent("_index.md"), atomically: true, encoding: .utf8)

        let (notes, children) = readDirectoryOrder(at: tmp.path)
        #expect(notes.isEmpty)
        #expect(children.isEmpty)
    }

    // MARK: - writeDirectoryOrder

    @Test func writeDirectoryOrder_createsIndexFile() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writeDirectoryOrder(at: tmp.path, notes: ["a.md", "b.md"])

        let (notes, _) = readDirectoryOrder(at: tmp.path)
        #expect(notes == ["a.md", "b.md"])
    }

    @Test func writeDirectoryOrder_preservesExistingTitle() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let content = """
        ---
        title: Keep Me
        ---
        Body text.
        """
        try content.write(to: tmp.appendingPathComponent("_index.md"), atomically: true, encoding: .utf8)

        try writeDirectoryOrder(at: tmp.path, notes: ["x.md"])

        let indexContent = try String(contentsOf: tmp.appendingPathComponent("_index.md"), encoding: .utf8)
        #expect(indexContent.contains("title: Keep Me"))
        #expect(indexContent.contains("x.md"))
    }

    @Test func writeDirectoryOrder_writesChildrenField() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writeDirectoryOrder(at: tmp.path, children: ["dir-a", "dir-b"])

        let (_, children) = readDirectoryOrder(at: tmp.path)
        #expect(children == ["dir-a", "dir-b"])
    }

    @Test func writeDirectoryOrder_emptyArrayRemovesField() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writeDirectoryOrder(at: tmp.path, notes: ["a.md"])
        let (notes1, _) = readDirectoryOrder(at: tmp.path)
        #expect(notes1 == ["a.md"])

        try writeDirectoryOrder(at: tmp.path, notes: [])
        let (notes2, _) = readDirectoryOrder(at: tmp.path)
        #expect(notes2.isEmpty)
    }

    @Test func writeDirectoryOrder_updatesOnlySpecifiedField() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try writeDirectoryOrder(at: tmp.path, notes: ["a.md"], children: ["sub"])
        try writeDirectoryOrder(at: tmp.path, notes: ["b.md"])

        let (notes, children) = readDirectoryOrder(at: tmp.path)
        #expect(notes == ["b.md"])
        #expect(children == ["sub"]) // children preserved
    }

    // MARK: - sortByOrder

    @Test func sortByOrder_emptyOrder_returnsOriginal() {
        let items = ["c", "a", "b"]
        let result = sortByOrder(items, order: []) { $0 }
        // Empty order → returns items unchanged (guard early return)
        #expect(result == ["c", "a", "b"])
    }

    @Test func sortByOrder_listsOrderedFirst_thenAlphabetical() {
        let items = ["d", "b", "a", "c"]
        let result = sortByOrder(items, order: ["c", "a"]) { $0 }
        #expect(result == ["c", "a", "b", "d"])
    }

    @Test func sortByOrder_allListed() {
        let items = ["b", "a", "c"]
        let result = sortByOrder(items, order: ["c", "b", "a"]) { $0 }
        #expect(result == ["c", "b", "a"])
    }

    @Test func sortByOrder_noneListed() {
        let items = ["c", "a", "b"]
        let result = sortByOrder(items, order: ["x", "y"]) { $0 }
        #expect(result == ["a", "b", "c"])
    }
}

@Suite("Vault: Move & Reorder")
struct VaultMoveReorderTests {
    private func makeTestVault() throws -> (Vault, URL) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("test-vault-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let yaml = """
        author:
          name: ""
        collections:
          - id: coll-a
            name: Collection A
            icon: star
            description: ""
          - id: coll-b
            name: Collection B
            icon: folder
            description: ""
        """
        try yaml.write(to: tmp.appendingPathComponent("maho.yaml"), atomically: true, encoding: .utf8)

        try fm.createDirectory(at: tmp.appendingPathComponent("coll-a"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmp.appendingPathComponent("coll-b"), withIntermediateDirectories: true)

        return (Vault(path: tmp.path), tmp)
    }

    // MARK: - reorderNotes

    @Test func reorderNotes_writesToIndexMd() throws {
        let (vault, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try vault.createNote(title: "First", collection: "coll-a", tags: [])
        _ = try vault.createNote(title: "Second", collection: "coll-a", tags: [])

        let result = try vault.reorderNotes(
            collectionId: "coll-a",
            orderedPaths: ["coll-a/second.md", "coll-a/first.md"]
        )
        #expect(result.isEmpty) // no renames

        let (order, _) = readDirectoryOrder(at: tmp.appendingPathComponent("coll-a").path)
        #expect(order == ["second.md", "first.md"])
    }

    // MARK: - moveNote

    @Test func moveNote_movesFileAndUpdatesOrder() throws {
        let (vault, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let relPath = try vault.createNote(title: "Movable", collection: "coll-a", tags: [])
        let newPath = try vault.moveNote(relativePath: relPath, toCollection: "coll-b")

        #expect(newPath.hasPrefix("coll-b/"))
        #expect(FileManager.default.fileExists(atPath: tmp.appendingPathComponent(newPath).path))
        #expect(!FileManager.default.fileExists(atPath: tmp.appendingPathComponent(relPath).path))

        // Check _index.md order updated
        let (sourceOrder, _) = readDirectoryOrder(at: tmp.appendingPathComponent("coll-a").path)
        #expect(!sourceOrder.contains("movable.md"))

        let (targetOrder, _) = readDirectoryOrder(at: tmp.appendingPathComponent("coll-b").path)
        #expect(targetOrder.contains((newPath as NSString).lastPathComponent))
    }

    @Test func moveNote_handlesFilenameConflict() throws {
        let (vault, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try vault.createNote(title: "Same Name", collection: "coll-a", tags: [])
        _ = try vault.createNote(title: "Same Name", collection: "coll-b", tags: [])

        let newPath = try vault.moveNote(relativePath: "coll-a/same-name.md", toCollection: "coll-b")
        // Should get a conflict suffix
        #expect(newPath.hasPrefix("coll-b/"))
        #expect(newPath.contains("same-name-1"))
    }

    // MARK: - moveCollection

    @Test func moveCollection_movesDirectoryAndUpdatesChildren() throws {
        let fm = FileManager.default
        let (vault, tmp) = try makeTestVault()
        defer { try? fm.removeItem(at: tmp) }

        // Create a sub-collection in coll-a
        let subDir = tmp.appendingPathComponent("coll-a/sub")
        try fm.createDirectory(at: subDir, withIntermediateDirectories: true)
        let indexContent = "---\ntitle: Sub\n---\n"
        try indexContent.write(to: subDir.appendingPathComponent("_index.md"), atomically: true, encoding: .utf8)

        let newPath = try vault.moveCollection(collectionId: "coll-a/sub", intoParent: "coll-b")
        #expect(newPath == "coll-b/sub")
        #expect(fm.fileExists(atPath: tmp.appendingPathComponent("coll-b/sub").path))
        #expect(!fm.fileExists(atPath: subDir.path))

        let (_, children) = readDirectoryOrder(at: tmp.appendingPathComponent("coll-b").path)
        #expect(children.contains("sub"))
    }

    @Test func moveCollection_preventsCircularMove() throws {
        let fm = FileManager.default
        let (vault, tmp) = try makeTestVault()
        defer { try? fm.removeItem(at: tmp) }

        let subDir = tmp.appendingPathComponent("coll-a/child")
        try fm.createDirectory(at: subDir, withIntermediateDirectories: true)

        // Can't move coll-a into coll-a/child (circular)
        #expect(throws: MoveError.self) {
            _ = try vault.moveCollection(collectionId: "coll-a", intoParent: "coll-a/child")
        }

        // Can't move into self
        #expect(throws: MoveError.self) {
            _ = try vault.moveCollection(collectionId: "coll-a", intoParent: "coll-a")
        }
    }

    @Test func moveCollection_preventsDestinationConflict() throws {
        let fm = FileManager.default
        let (vault, tmp) = try makeTestVault()
        defer { try? fm.removeItem(at: tmp) }

        // Create sub in both collections
        try fm.createDirectory(at: tmp.appendingPathComponent("coll-a/shared"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmp.appendingPathComponent("coll-b/shared"), withIntermediateDirectories: true)

        #expect(throws: MoveError.self) {
            _ = try vault.moveCollection(collectionId: "coll-a/shared", intoParent: "coll-b")
        }
    }

    // MARK: - reorderSubCollections

    @Test func reorderSubCollections_writesToParentIndex() throws {
        let fm = FileManager.default
        let (vault, tmp) = try makeTestVault()
        defer { try? fm.removeItem(at: tmp) }

        try fm.createDirectory(at: tmp.appendingPathComponent("coll-a/sub-x"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmp.appendingPathComponent("coll-a/sub-y"), withIntermediateDirectories: true)

        try vault.reorderSubCollections(parentId: "coll-a", orderedIds: ["coll-a/sub-y", "coll-a/sub-x"])

        let (_, children) = readDirectoryOrder(at: tmp.appendingPathComponent("coll-a").path)
        #expect(children == ["sub-y", "sub-x"])
    }

    // MARK: - buildFileTree respects _index.md ordering

    @Test func buildFileTree_respectsNoteOrder() throws {
        let (vault, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try vault.createNote(title: "Alpha", collection: "coll-a", tags: [])
        _ = try vault.createNote(title: "Beta", collection: "coll-a", tags: [])
        _ = try vault.createNote(title: "Gamma", collection: "coll-a", tags: [])

        // Set order: gamma, alpha, beta
        try writeDirectoryOrder(
            at: tmp.appendingPathComponent("coll-a").path,
            notes: ["gamma.md", "alpha.md", "beta.md"]
        )

        let tree = try vault.buildFileTree()
        let collA = tree.first { $0.id == "coll-a" }
        let noteChildren = collA?.children.filter { !$0.isDirectory } ?? []
        let titles = noteChildren.map { $0.name }
        #expect(titles == ["Gamma", "Alpha", "Beta"])
    }

    @Test func buildFileTree_respectsChildOrder() throws {
        let fm = FileManager.default
        let (vault, tmp) = try makeTestVault()
        defer { try? fm.removeItem(at: tmp) }

        try fm.createDirectory(at: tmp.appendingPathComponent("coll-a/zzz"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmp.appendingPathComponent("coll-a/aaa"), withIntermediateDirectories: true)

        // Create _index.md in each subdirectory (so they're valid)
        try "---\ntitle: ZZZ\n---\n".write(
            to: tmp.appendingPathComponent("coll-a/zzz/_index.md"), atomically: true, encoding: .utf8)
        try "---\ntitle: AAA\n---\n".write(
            to: tmp.appendingPathComponent("coll-a/aaa/_index.md"), atomically: true, encoding: .utf8)

        // Also add a note in each so they appear in the tree via note paths
        _ = try vault.createNote(title: "Z Note", collection: "coll-a/zzz", tags: [])
        _ = try vault.createNote(title: "A Note", collection: "coll-a/aaa", tags: [])

        // Order: zzz before aaa
        try writeDirectoryOrder(at: tmp.appendingPathComponent("coll-a").path, children: ["zzz", "aaa"])

        let tree = try vault.buildFileTree()
        let collA = tree.first { $0.id == "coll-a" }
        let dirChildren = collA?.children.filter { $0.isDirectory } ?? []
        let names = dirChildren.map { $0.name }
        #expect(names == ["ZZZ", "AAA"])
    }

    @Test func buildFileTree_unlistedFilesAppendedAlphabetically() throws {
        let (vault, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try vault.createNote(title: "Alpha", collection: "coll-a", tags: [])
        _ = try vault.createNote(title: "Beta", collection: "coll-a", tags: [])
        _ = try vault.createNote(title: "Gamma", collection: "coll-a", tags: [])

        // Only list gamma — alpha and beta should be appended alphabetically
        try writeDirectoryOrder(
            at: tmp.appendingPathComponent("coll-a").path,
            notes: ["gamma.md"]
        )

        let tree = try vault.buildFileTree()
        let collA = tree.first { $0.id == "coll-a" }
        let noteChildren = collA?.children.filter { !$0.isDirectory } ?? []
        let titles = noteChildren.map { $0.name }
        #expect(titles.first == "Gamma")
        #expect(titles.count == 3)
        // Alpha and Beta should follow, alphabetically
        #expect(titles[1] == "Alpha")
        #expect(titles[2] == "Beta")
    }
}
