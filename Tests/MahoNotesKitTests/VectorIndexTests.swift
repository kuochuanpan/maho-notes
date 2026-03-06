import Testing
import Foundation
@testable import MahoNotesKit
import CJKSQLite

@Suite("VectorIndex")
struct VectorIndexTests {

    // MARK: - Helpers

    private func makeTempVault() throws -> (Vault, URL) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("test-vec-vault-\(UUID().uuidString)")
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

    private func createNote(in vaultURL: URL, collection: String, filename: String, title: String, body: String) throws {
        let fm = FileManager.default
        let collDir = vaultURL.appendingPathComponent(collection)
        if !fm.fileExists(atPath: collDir.path) {
            try fm.createDirectory(at: collDir, withIntermediateDirectories: true)
        }

        let content = """
        ---
        title: \(title)
        tags: []
        created: 2026-01-01T00:00:00+00:00
        updated: 2026-01-01T00:00:00+00:00
        public: false
        author: test
        ---

        \(body)
        """
        try content.write(to: collDir.appendingPathComponent(filename), atomically: true, encoding: .utf8)
    }

    /// Generate a simple deterministic vector for testing.
    private func makeVector(seed: Float, dimensions: Int = 384) -> [Float] {
        (0..<dimensions).map { i in sin(seed * Float(i + 1) * 0.01) }
    }

    /// A dummy embedder that returns deterministic vectors based on text hash.
    private func dummyEmbedder(_ texts: [String]) -> [[Float]] {
        texts.map { text in
            let seed = Float(abs(text.hashValue % 1000))
            return makeVector(seed: seed)
        }
    }

    // MARK: - Tests

    @Test func schemaCreation() throws {
        let (_, tmp) = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try VectorIndex(vaultPath: tmp.path)

        // Verify tables exist by opening the DB directly
        let dbPath = tmp.appendingPathComponent(".maho/index.db").path
        let db = try Database(path: dbPath)
        let tables = try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('chunks', '_vec_schema') ORDER BY name")
        let tableNames = tables.compactMap { $0["name"] }
        #expect(tableNames.contains("chunks"))
        #expect(tableNames.contains("_vec_schema"))
    }

    @Test func indexNoteWithTwoChunks() throws {
        let (_, tmp) = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vi = try VectorIndex(vaultPath: tmp.path)

        let chunks: [(id: Int, text: String)] = [
            (id: 0, text: "First paragraph about physics."),
            (id: 1, text: "Second paragraph about chemistry.")
        ]
        let vectors = chunks.map { makeVector(seed: Float($0.id + 1)) }

        try vi.indexNote(path: "notes/test.md", chunks: chunks, vectors: vectors, model: "test-model", mtime: 100.0)

        // Verify chunks table
        let dbPath = tmp.appendingPathComponent(".maho/index.db").path
        let db = try Database(path: dbPath)
        let rows = try db.query("SELECT * FROM chunks WHERE path = 'notes/test.md' ORDER BY chunk_id")
        #expect(rows.count == 2)
        #expect(rows[0]["chunk_id"] == "0")
        #expect(rows[1]["chunk_id"] == "1")
        #expect(rows[0]["model"] == "test-model")

        // Verify vec_chunks has rows too
        let vecRows = try db.query("SELECT COUNT(*) as cnt FROM vec_chunks")
        let cnt = Int(vecRows.first?["cnt"] ?? "0") ?? 0
        #expect(cnt == 2)
    }

    @Test func searchReturnsCorrectResults() throws {
        let (_, tmp) = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vi = try VectorIndex(vaultPath: tmp.path)

        // Insert two notes with distinct vectors
        let vec1 = makeVector(seed: 1.0)
        let vec2 = makeVector(seed: 50.0)

        try vi.indexNote(path: "notes/a.md", chunks: [(id: 0, text: "Alpha content")], vectors: [vec1], model: "test", mtime: 100.0)
        try vi.indexNote(path: "notes/b.md", chunks: [(id: 0, text: "Beta content")], vectors: [vec2], model: "test", mtime: 100.0)

        // Query with vec1 — should rank notes/a.md higher
        let results = try vi.search(queryVector: vec1, limit: 10, minScore: 0)
        #expect(results.count == 2)
        #expect(results[0].path == "notes/a.md")
        #expect(results[0].score > results[1].score)
    }

    @Test func removeNoteDeletesChunksAndVectors() throws {
        let (_, tmp) = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vi = try VectorIndex(vaultPath: tmp.path)

        try vi.indexNote(
            path: "notes/remove-me.md",
            chunks: [(id: 0, text: "Will be removed")],
            vectors: [makeVector(seed: 1.0)],
            model: "test",
            mtime: 100.0
        )

        // Verify exists
        let dbPath = tmp.appendingPathComponent(".maho/index.db").path
        let db = try Database(path: dbPath)
        var rows = try db.query("SELECT COUNT(*) as cnt FROM chunks")
        #expect(Int(rows.first?["cnt"] ?? "0") == 1)

        // Remove
        try vi.removeNote(path: "notes/remove-me.md")

        rows = try db.query("SELECT COUNT(*) as cnt FROM chunks")
        #expect(Int(rows.first?["cnt"] ?? "0") == 0)

        let vecRows = try db.query("SELECT COUNT(*) as cnt FROM vec_chunks")
        #expect(Int(vecRows.first?["cnt"] ?? "0") == 0)
    }

    @Test func incrementalSkipsUnchanged() throws {
        let (vault, tmp) = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try createNote(in: tmp, collection: "notes", filename: "001-stable.md", title: "Stable", body: "Unchanged content.")

        let vi = try VectorIndex(vaultPath: tmp.path)
        let notes = try vault.allNotes()

        // First build
        let stats1 = try vi.buildIndex(notes: notes, embedder: dummyEmbedder, model: "test")
        #expect(stats1.added == 1)

        // Second build — same mtime, should skip
        let stats2 = try vi.buildIndex(notes: notes, embedder: dummyEmbedder, model: "test")
        #expect(stats2.added == 0)
        #expect(stats2.updated == 0)
    }

    @Test func fullRebuildClearsAndReinserts() throws {
        let (vault, tmp) = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try createNote(in: tmp, collection: "notes", filename: "001-note.md", title: "Note", body: "Content here.")

        let vi = try VectorIndex(vaultPath: tmp.path)
        let notes = try vault.allNotes()

        let stats1 = try vi.buildIndex(notes: notes, embedder: dummyEmbedder, model: "test")
        #expect(stats1.added == 1)

        // Full rebuild
        let stats2 = try vi.buildIndex(notes: notes, embedder: dummyEmbedder, model: "test", fullRebuild: true)
        #expect(stats2.added == 1)
        #expect(stats2.totalChunks >= 1)

        // Search still works
        let results = try vi.search(queryVector: dummyEmbedder(["Content here."])[0], limit: 5, minScore: 0)
        #expect(!results.isEmpty)
    }

    @Test func coexistenceWithFTS5() throws {
        let (vault, tmp) = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try createNote(in: tmp, collection: "notes", filename: "001-coexist.md", title: "Coexistence Test", body: "Both FTS5 and vec0 in the same DB.")

        let notes = try vault.allNotes()

        // Build FTS5 index
        let searchIndex = try SearchIndex(vaultPath: tmp.path)
        let ftsStats = try searchIndex.buildIndex(notes: notes)
        #expect(ftsStats.added == 1)

        // Build vector index in same DB
        let vecIndex = try VectorIndex(vaultPath: tmp.path)
        let vecStats = try vecIndex.buildIndex(notes: notes, embedder: dummyEmbedder, model: "test")
        #expect(vecStats.added == 1)

        // FTS5 search still works
        let ftsResults = try searchIndex.search(query: "Coexistence")
        #expect(!ftsResults.isEmpty)

        // Vector search works
        let vecResults = try vecIndex.search(queryVector: dummyEmbedder(["Both FTS5 and vec0 in the same DB."])[0], limit: 5, minScore: 0)
        #expect(!vecResults.isEmpty)
    }

    @Test func dimensionMismatchThrows() throws {
        let (_, tmp) = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Create index with 384 dimensions
        _ = try VectorIndex(vaultPath: tmp.path, dimensions: 384)

        // Opening with different dimensions should throw
        #expect(throws: VectorIndexError.self) {
            _ = try VectorIndex(vaultPath: tmp.path, dimensions: 1024)
        }
    }

    @Test func dimensionMismatchErrorMessage() throws {
        let error = VectorIndexError.dimensionMismatch(stored: 384, requested: 1024)
        #expect(error.errorDescription?.contains("384") == true)
        #expect(error.errorDescription?.contains("1024") == true)
        #expect(error.errorDescription?.contains("mn index --full") == true)
    }

    @Test func noteLevelAggregation() throws {
        let (_, tmp) = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vi = try VectorIndex(vaultPath: tmp.path)

        // Insert one note with 3 chunks, each with a different vector
        let chunks: [(id: Int, text: String)] = [
            (id: 0, text: "Introduction paragraph"),
            (id: 1, text: "Main content paragraph"),
            (id: 2, text: "Conclusion paragraph")
        ]
        let queryVec = makeVector(seed: 2.0)
        let vectors = [
            makeVector(seed: 2.0),  // chunk 0: very similar to query
            makeVector(seed: 30.0), // chunk 1: less similar
            makeVector(seed: 60.0)  // chunk 2: even less similar
        ]

        try vi.indexNote(path: "notes/multi-chunk.md", chunks: chunks, vectors: vectors, model: "test", mtime: 100.0)

        // Also insert a second note with a moderately similar vector
        try vi.indexNote(path: "notes/other.md", chunks: [(id: 0, text: "Other note")], vectors: [makeVector(seed: 5.0)], model: "test", mtime: 100.0)

        let results = try vi.search(queryVector: queryVec, limit: 10, minScore: 0)

        // Should have exactly 2 results (one per note, not 4)
        #expect(results.count == 2)

        // The multi-chunk note should appear with its best chunk (chunk 0)
        let multiChunkResult = results.first { $0.path == "notes/multi-chunk.md" }
        #expect(multiChunkResult != nil)
        #expect(multiChunkResult?.chunkId == 0)
        #expect(multiChunkResult?.chunkText == "Introduction paragraph")
    }
}
