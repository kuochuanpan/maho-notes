import Testing
import Foundation
@testable import MahoNotesKit
import CJKSQLite

@Suite("SearchIndex")
struct SearchIndexTests {

    // MARK: - Helpers

    private func makeTempVault() throws -> (Vault, URL) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("test-vault-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let mahoYaml = """
        author:
          name: Test User
        collections:
          - id: notes
            name: Notes
            icon: note.text
            description: Test notes
        """
        try mahoYaml.write(to: tmp.appendingPathComponent("maho.yaml"), atomically: true, encoding: .utf8)

        return (Vault(path: tmp.path), tmp)
    }

    private func createNote(in vaultURL: URL, collection: String, filename: String, title: String, tags: [String], body: String) throws {
        let fm = FileManager.default
        let collDir = vaultURL.appendingPathComponent(collection)
        if !fm.fileExists(atPath: collDir.path) {
            try fm.createDirectory(at: collDir, withIntermediateDirectories: true)
        }

        let tagsYaml = tags.isEmpty ? "[]" : "[\(tags.joined(separator: ", "))]"
        let content = """
        ---
        title: \(title)
        tags: \(tagsYaml)
        created: 2026-01-01T00:00:00+00:00
        updated: 2026-01-01T00:00:00+00:00
        public: false
        author: test
        ---

        \(body)
        """
        try content.write(to: collDir.appendingPathComponent(filename), atomically: true, encoding: .utf8)
    }

    // MARK: - Tests

    @Test func indexBuild() throws {
        let (vault, tmp) = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try createNote(in: tmp, collection: "notes", filename: "001-hello.md",
                       title: "Hello World", tags: ["test"], body: "This is a test note about hello world.")
        try createNote(in: tmp, collection: "notes", filename: "002-second.md",
                       title: "Second Note", tags: ["test"], body: "Another note with different content.")

        let index = try SearchIndex(vaultPath: vault.path)
        let notes = try vault.allNotes()
        let stats = try index.buildIndex(notes: notes)

        #expect(stats.added == 2)
        #expect(stats.updated == 0)
        #expect(stats.deleted == 0)
        #expect(stats.total == 2)
    }

    @Test func indexFullRebuild() throws {
        let (vault, tmp) = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try createNote(in: tmp, collection: "notes", filename: "001-hello.md",
                       title: "Hello World", tags: ["test"], body: "A test note.")

        let index = try SearchIndex(vaultPath: vault.path)
        let notes = try vault.allNotes()

        // First build
        let stats1 = try index.buildIndex(notes: notes)
        #expect(stats1.added == 1)

        // Full rebuild
        let stats2 = try index.buildIndex(notes: notes, fullRebuild: true)
        #expect(stats2.added == 1)
        #expect(stats2.updated == 0)
        #expect(stats2.total == 1)

        // Search still works
        let results = try index.search(query: "Hello")
        #expect(results.count == 1)
    }

    @Test func incrementalUpdate() throws {
        let (vault, tmp) = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try createNote(in: tmp, collection: "notes", filename: "001-hello.md",
                       title: "Hello World", tags: ["test"], body: "Original content.")
        try createNote(in: tmp, collection: "notes", filename: "002-other.md",
                       title: "Other Note", tags: ["test"], body: "Unchanged content.")

        let index = try SearchIndex(vaultPath: vault.path)
        var notes = try vault.allNotes()
        try index.buildIndex(notes: notes)

        // Wait so mtime clearly differs, then modify only one note
        Thread.sleep(forTimeInterval: 2.0)
        let modifiedPath = tmp.appendingPathComponent("notes/001-hello.md")
        let newContent = """
        ---
        title: Hello Updated
        tags: [test, updated]
        created: 2026-01-01T00:00:00+00:00
        updated: 2026-01-01T00:00:00+00:00
        public: false
        author: test
        ---

        Modified content with new stuff.
        """
        try newContent.write(to: modifiedPath, atomically: true, encoding: .utf8)

        notes = try vault.allNotes()
        let stats = try index.buildIndex(notes: notes)

        #expect(stats.updated >= 1, "At least the modified note should be updated")
        #expect(stats.deleted == 0)
        #expect(stats.total == 2)

        // Verify updated content is searchable
        let results = try index.search(query: "Modified")
        #expect(results.count == 1)
    }

    @Test func incrementalDelete() throws {
        let (vault, tmp) = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try createNote(in: tmp, collection: "notes", filename: "001-hello.md",
                       title: "Hello", tags: [], body: "Content one.")
        try createNote(in: tmp, collection: "notes", filename: "002-goodbye.md",
                       title: "Goodbye", tags: [], body: "Content two.")

        let index = try SearchIndex(vaultPath: vault.path)
        var notes = try vault.allNotes()
        try index.buildIndex(notes: notes)

        // Delete one note file
        try FileManager.default.removeItem(at: tmp.appendingPathComponent("notes/002-goodbye.md"))

        notes = try vault.allNotes()
        let stats = try index.buildIndex(notes: notes)

        #expect(stats.deleted == 1)
        #expect(stats.total == 1)

        // Deleted note should not appear in search
        let results = try index.search(query: "Goodbye")
        #expect(results.isEmpty)
    }

    @Test func cjkSearch() throws {
        let (vault, tmp) = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Chinese
        try createNote(in: tmp, collection: "notes", filename: "001-chinese.md",
                       title: "超新星爆炸", tags: ["天文"], body: "微中子是超新星爆炸中最重要的粒子。核心塌縮產生大量能量。")
        // Japanese
        try createNote(in: tmp, collection: "notes", filename: "002-japanese.md",
                       title: "ニュートリノ物理", tags: ["物理"], body: "超新星ニュートリノは宇宙物理学の重要な研究対象です。")
        // Korean
        try createNote(in: tmp, collection: "notes", filename: "003-korean.md",
                       title: "초신성 관측", tags: ["천문학"], body: "중력파 검출기를 이용한 초신성 관측은 현대 천문학의 중요한 연구 분야입니다.")
        // English
        try createNote(in: tmp, collection: "notes", filename: "004-english.md",
                       title: "Supernova Neutrinos", tags: ["astrophysics"], body: "Core-collapse supernovae release enormous amounts of energy via neutrino emission.")

        let index = try SearchIndex(vaultPath: vault.path)
        let notes = try vault.allNotes()
        try index.buildIndex(notes: notes)

        // Search in each language
        let zhResults = try index.search(query: "微中子")
        #expect(!zhResults.isEmpty, "Chinese search should find results")

        let jaResults = try index.search(query: "ニュートリノ")
        #expect(!jaResults.isEmpty, "Japanese search should find results")

        let koResults = try index.search(query: "중력파")
        #expect(!koResults.isEmpty, "Korean search should find results")

        let enResults = try index.search(query: "neutrino")
        #expect(!enResults.isEmpty, "English search should find results")
    }

    @Test func mixedLanguageNote() throws {
        let (vault, tmp) = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try createNote(in: tmp, collection: "notes", filename: "001-mixed.md",
                       title: "Multilingual Note",
                       tags: ["multilingual"],
                       body: """
                       This note contains multiple languages.
                       超新星爆炸是宇宙中最壯觀的事件。
                       超新星ニュートリノは非常に重要です。
                       초신성은 우주에서 가장 강력한 폭발입니다.
                       """)

        let index = try SearchIndex(vaultPath: vault.path)
        let notes = try vault.allNotes()
        try index.buildIndex(notes: notes)

        // All four languages should find this note
        #expect(try !index.search(query: "languages").isEmpty)
        #expect(try !index.search(query: "超新星").isEmpty)
        #expect(try !index.search(query: "ニュートリノ").isEmpty)
        #expect(try !index.search(query: "초신성").isEmpty)
    }

    @Test func rankingOrder() throws {
        let (vault, tmp) = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Note with "neutrino" in title
        try createNote(in: tmp, collection: "notes", filename: "001-title-match.md",
                       title: "Neutrino Physics", tags: ["physics"],
                       body: "This note discusses various topics in particle physics.")
        // Note with "neutrino" only in body
        try createNote(in: tmp, collection: "notes", filename: "002-body-match.md",
                       title: "Astrophysics Overview", tags: ["astro"],
                       body: "Supernova neutrino emission is a key process in stellar death.")

        let index = try SearchIndex(vaultPath: vault.path)
        let notes = try vault.allNotes()
        try index.buildIndex(notes: notes)

        let results = try index.search(query: "neutrino")
        #expect(results.count == 2)
        // Title match should rank higher (more negative bm25 = first in ASC order)
        #expect(results[0].title == "Neutrino Physics", "Title match should rank first")
    }

    @Test func emptyVault() throws {
        let (vault, tmp) = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let index = try SearchIndex(vaultPath: vault.path)
        let notes = try vault.allNotes()
        let stats = try index.buildIndex(notes: notes)

        #expect(stats.added == 0)
        #expect(stats.total == 0)

        let results = try index.search(query: "anything")
        #expect(results.isEmpty)
    }

    @Test func noMatch() throws {
        let (vault, tmp) = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try createNote(in: tmp, collection: "notes", filename: "001-hello.md",
                       title: "Hello", tags: ["test"], body: "Some content here.")

        let index = try SearchIndex(vaultPath: vault.path)
        let notes = try vault.allNotes()
        try index.buildIndex(notes: notes)

        let results = try index.search(query: "xyznonexistent")
        #expect(results.isEmpty)
    }

    @Test func corruptDBRecovery() throws {
        let (_, tmp) = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Create .maho directory and write garbage to index.db
        let mahoDir = tmp.appendingPathComponent(".maho")
        try FileManager.default.createDirectory(at: mahoDir, withIntermediateDirectories: true)
        let dbPath = mahoDir.appendingPathComponent("index.db")
        try "THIS IS NOT A SQLITE DATABASE".write(to: dbPath, atomically: true, encoding: .utf8)

        // SearchIndex should handle corrupt DB (delete and recreate)
        let index = try SearchIndex(vaultPath: tmp.path)
        // Should be able to build and search without error
        let stats = try index.buildIndex(notes: [])
        #expect(stats.total == 0)
    }

    @Test func autoIndexDetection() throws {
        let (vault, tmp) = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // No index.db yet
        #expect(!SearchIndex.indexExists(vaultPath: vault.path))

        // Create index
        let index = try SearchIndex(vaultPath: vault.path)
        try index.buildIndex(notes: [])

        // Now it should exist
        #expect(SearchIndex.indexExists(vaultPath: vault.path))
    }
}
