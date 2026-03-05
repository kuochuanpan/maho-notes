import Foundation
import CJKSQLite

/// A single vector search result.
public struct VectorSearchResult: Sendable {
    public let path: String
    public let chunkText: String
    public let score: Double
    public let chunkId: Int
}

/// Statistics from a vector index build operation.
public struct VectorIndexStats: Sendable, Codable {
    public let added: Int
    public let updated: Int
    public let deleted: Int
    public let totalChunks: Int
}

/// Errors specific to VectorIndex operations.
public enum VectorIndexError: Error, LocalizedError {
    case indexCorrupt(message: String)
    case queryFailed(message: String)
    case modelMismatch(stored: String, requested: String)

    public var errorDescription: String? {
        switch self {
        case .indexCorrupt(let msg): return "Vector index corrupt: \(msg)"
        case .queryFailed(let msg): return "Vector query failed: \(msg)"
        case .modelMismatch(let stored, let requested):
            return "Model mismatch: index uses '\(stored)' but '\(requested)' was requested. Rebuild with fullRebuild: true."
        }
    }
}

private let currentVecSchemaVersion = 1

/// Vector embedding index backed by sqlite-vec, stored in the same index.db as SearchIndex.
public final class VectorIndex: @unchecked Sendable {
    private let db: Database
    private let vaultPath: String
    private let dimensions: Int

    /// Open or create the vector index at `.maho/index.db` inside the vault.
    public init(vaultPath: String, dimensions: Int = 384) throws {
        self.vaultPath = (vaultPath as NSString).expandingTildeInPath
        self.dimensions = dimensions
        let mahoDir = (self.vaultPath as NSString).appendingPathComponent(".maho")
        let fm = FileManager.default

        if !fm.fileExists(atPath: mahoDir) {
            try fm.createDirectory(atPath: mahoDir, withIntermediateDirectories: true)
        }

        let dbPath = (mahoDir as NSString).appendingPathComponent("index.db")

        do {
            self.db = try Database(path: dbPath)
        } catch {
            try? fm.removeItem(atPath: dbPath)
            self.db = try Database(path: dbPath)
        }

        try ensureSchema()
    }

    /// Initialize with an explicit Database instance (for testing).
    internal init(database: Database, vaultPath: String, dimensions: Int = 384) throws {
        self.db = database
        self.vaultPath = vaultPath
        self.dimensions = dimensions
        try ensureSchema()
    }

    // MARK: - Schema Management

    private func ensureSchema() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS _vec_schema(version INTEGER)
        """)

        let rows = try db.query("SELECT version FROM _vec_schema LIMIT 1")
        let existingVersion = rows.first.flatMap { $0["version"] }.flatMap { Int($0) }

        if let v = existingVersion, v == currentVecSchemaVersion {
            return
        }

        if existingVersion != nil {
            try dropVecTables()
            try db.execute("CREATE TABLE IF NOT EXISTS _vec_schema(version INTEGER)")
        }

        try db.createVecTable(name: "vec_chunks", dimensions: dimensions)

        try db.execute("""
            CREATE TABLE IF NOT EXISTS chunks(
                id INTEGER PRIMARY KEY,
                path TEXT NOT NULL,
                chunk_id INTEGER NOT NULL,
                chunk_text TEXT NOT NULL,
                model TEXT NOT NULL,
                mtime REAL NOT NULL
            )
        """)

        try db.execute("CREATE INDEX IF NOT EXISTS idx_chunks_path ON chunks(path)")

        if existingVersion == nil {
            try db.execute("INSERT INTO _vec_schema(version) VALUES (\(currentVecSchemaVersion))")
        } else {
            try db.execute("UPDATE _vec_schema SET version = \(currentVecSchemaVersion)")
        }
    }

    private func dropVecTables() throws {
        try db.execute("DROP TABLE IF EXISTS vec_chunks")
        try db.execute("DROP TABLE IF EXISTS chunks")
        try db.execute("DROP TABLE IF EXISTS _vec_schema")
    }

    // MARK: - Indexing

    /// Index a single note's chunks and vectors.
    public func indexNote(path: String, chunks: [(id: Int, text: String)], vectors: [[Float]], model: String, mtime: Double) throws {
        // Remove old chunks for this path
        try removeNote(path: path)

        let escapedPath = escapeSQLString(path)
        let escapedModel = escapeSQLString(model)

        for (i, chunk) in chunks.enumerated() {
            let escapedText = escapeSQLString(chunk.text)
            try db.execute("""
                INSERT INTO chunks(path, chunk_id, chunk_text, model, mtime)
                VALUES ('\(escapedPath)', \(chunk.id), '\(escapedText)', '\(escapedModel)', \(mtime))
            """)

            // Get the rowid just inserted
            let lastRow = try db.query("SELECT last_insert_rowid() as rid")
            guard let ridStr = lastRow.first?["rid"], let rid = Int64(ridStr) else {
                throw VectorIndexError.indexCorrupt(message: "Failed to get last insert rowid")
            }

            try db.insertVector(table: "vec_chunks", rowid: rid, vector: vectors[i])
        }
    }

    /// Remove all chunks and vectors for a note.
    public func removeNote(path: String) throws {
        let escapedPath = escapeSQLString(path)

        // Get rowids to delete from vec_chunks
        let rows = try db.query("SELECT id FROM chunks WHERE path = '\(escapedPath)'")
        for row in rows {
            if let idStr = row["id"], let id = Int64(idStr) {
                try db.deleteVector(table: "vec_chunks", rowid: id)
            }
        }

        try db.execute("DELETE FROM chunks WHERE path = '\(escapedPath)'")
    }

    /// Build or update the vector index from the given notes.
    @discardableResult
    public func buildIndex(
        notes: [Note],
        embedder: ([String]) -> [[Float]],
        model: String,
        fullRebuild: Bool = false
    ) throws -> VectorIndexStats {
        // Check for model mismatch
        if !fullRebuild, let storedModel = try currentModel(), storedModel != model {
            throw VectorIndexError.modelMismatch(stored: storedModel, requested: model)
        }

        if fullRebuild {
            try db.execute("DELETE FROM chunks")
            // vec0 tables: delete all vectors by selecting all rowids
            let allRows = try db.query("SELECT id FROM chunks")
            // After deleting chunks, vec_chunks may still have rows — drop and recreate
            try db.execute("DROP TABLE IF EXISTS vec_chunks")
            try db.createVecTable(name: "vec_chunks", dimensions: dimensions)
        }

        var notesByPath: [String: Note] = [:]
        for note in notes {
            notesByPath[note.relativePath] = note
        }

        // Get existing indexed paths
        let existingRows = try db.query("SELECT DISTINCT path, mtime FROM chunks")
        var existingMtimes: [String: Double] = [:]
        for row in existingRows {
            if let path = row["path"], let mtimeStr = row["mtime"], let mtime = Double(mtimeStr) {
                existingMtimes[path] = mtime
            }
        }

        var added = 0
        var updated = 0
        var deleted = 0

        for note in notes {
            let filePath = (vaultPath as NSString).appendingPathComponent(note.relativePath)
            let fileMtime = Self.fileMtime(atPath: filePath)

            if let existingMtime = existingMtimes[note.relativePath] {
                if abs(fileMtime - existingMtime) > 0.001 {
                    let chunks = chunkNote(note)
                    if !chunks.isEmpty {
                        let texts = chunks.map { $0.text }
                        let vectors = embedder(texts)
                        try indexNote(path: note.relativePath, chunks: chunks, vectors: vectors, model: model, mtime: fileMtime)
                    }
                    updated += 1
                }
            } else {
                let chunks = chunkNote(note)
                if !chunks.isEmpty {
                    let texts = chunks.map { $0.text }
                    let vectors = embedder(texts)
                    try indexNote(path: note.relativePath, chunks: chunks, vectors: vectors, model: model, mtime: fileMtime)
                }
                added += 1
            }
        }

        // Prune deleted notes
        let currentPaths = Set(notesByPath.keys)
        for existingPath in existingMtimes.keys {
            if !currentPaths.contains(existingPath) {
                try removeNote(path: existingPath)
                deleted += 1
            }
        }

        let countRows = try db.query("SELECT COUNT(*) as cnt FROM chunks")
        let totalChunks = countRows.first.flatMap { $0["cnt"] }.flatMap { Int($0) } ?? 0

        return VectorIndexStats(added: added, updated: updated, deleted: deleted, totalChunks: totalChunks)
    }

    // MARK: - Search

    /// Search for notes matching the query vector. Returns results aggregated by note path (best chunk score per note).
    public func search(queryVector: [Float], limit: Int = 10) throws -> [VectorSearchResult] {
        // Fetch more raw results than limit to allow aggregation
        let rawLimit = limit * 3
        let vecResults = try db.searchVectors(table: "vec_chunks", query: queryVector, limit: rawLimit)

        guard !vecResults.isEmpty else { return [] }

        // Look up chunk metadata and aggregate by path (best score per note)
        var bestByPath: [String: VectorSearchResult] = [:]

        for result in vecResults {
            let rows = try db.query("SELECT path, chunk_text, chunk_id FROM chunks WHERE id = \(result.rowid)")
            guard let row = rows.first,
                  let path = row["path"],
                  let chunkText = row["chunk_text"],
                  let chunkIdStr = row["chunk_id"],
                  let chunkId = Int(chunkIdStr) else { continue }

            let score = 1.0 - result.distance

            if let existing = bestByPath[path] {
                if score > existing.score {
                    bestByPath[path] = VectorSearchResult(path: path, chunkText: chunkText, score: score, chunkId: chunkId)
                }
            } else {
                bestByPath[path] = VectorSearchResult(path: path, chunkText: chunkText, score: score, chunkId: chunkId)
            }
        }

        return Array(bestByPath.values)
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Utilities

    /// Check if a note needs re-indexing based on file mtime.
    public func needsReindex(path: String, mtime: Double) throws -> Bool {
        let escapedPath = escapeSQLString(path)
        let rows = try db.query("SELECT mtime FROM chunks WHERE path = '\(escapedPath)' LIMIT 1")
        guard let row = rows.first, let storedStr = row["mtime"], let stored = Double(storedStr) else {
            return true // Not indexed yet
        }
        return mtime > stored
    }

    /// Get the model identifier used in the current index, if any.
    public func currentModel() throws -> String? {
        let rows = try db.query("SELECT model FROM chunks LIMIT 1")
        return rows.first?["model"]
    }

    /// Check whether vector index tables exist in the vault's index.db.
    public static func vectorIndexExists(vaultPath: String) -> Bool {
        let expanded = (vaultPath as NSString).expandingTildeInPath
        let dbPath = (expanded as NSString).appendingPathComponent(".maho/index.db")
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbPath) else { return false }

        guard let db = try? Database(path: dbPath) else { return false }
        let rows = try? db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='chunks'")
        return (rows?.count ?? 0) > 0
    }

    // MARK: - Helpers

    /// Simple chunking: split note body into paragraphs.
    private func chunkNote(_ note: Note) -> [(id: Int, text: String)] {
        let paragraphs = note.body
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if paragraphs.isEmpty && !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [(id: 0, text: note.body.trimmingCharacters(in: .whitespacesAndNewlines))]
        }

        return paragraphs.enumerated().map { (id: $0.offset, text: $0.element) }
    }

    private func escapeSQLString(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }

    private static func fileMtime(atPath path: String) -> Double {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else {
            return 0
        }
        return date.timeIntervalSince1970
    }
}
