import Foundation
import CJKSQLite

/// A single vector search result.
public struct VectorSearchResult: Sendable {
    public let path: String
    public let chunkText: String
    public let score: Double
    public let chunkId: Int

    public init(path: String, chunkText: String, score: Double, chunkId: Int) {
        self.path = path
        self.chunkText = chunkText
        self.score = score
        self.chunkId = chunkId
    }
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
    case dimensionMismatch(stored: Int, requested: Int)

    public var errorDescription: String? {
        switch self {
        case .indexCorrupt(let msg): return "Vector index corrupt: \(msg)"
        case .queryFailed(let msg): return "Vector query failed: \(msg)"
        case .modelMismatch(let stored, let requested):
            return "Model mismatch: index uses '\(stored)' but '\(requested)' was requested. Rebuild with fullRebuild: true."
        case .dimensionMismatch(let stored, let requested):
            return "Dimension mismatch: index has \(stored) dimensions but \(requested) requested. Run `mn index --full` to rebuild."
        }
    }
}

private let currentVecSchemaVersion = 1

/// Vector embedding index backed by sqlite-vec, stored in the same index.db as SearchIndex.
public final class VectorIndex: @unchecked Sendable {
    private let db: Database
    private let vaultPath: String
    private let dimensions: Int
    private let skipDimensionCheck: Bool

    /// Open or create the vector index at `.maho/index.db` inside the vault.
    public init(vaultPath: String, dimensions: Int = 384, skipDimensionCheck: Bool = false) throws {
        self.vaultPath = (vaultPath as NSString).expandingTildeInPath
        self.dimensions = dimensions
        self.skipDimensionCheck = skipDimensionCheck
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

        try db.execute("PRAGMA journal_mode=WAL")

        try ensureSchema()
    }

    /// Initialize with an explicit Database instance (for testing).
    internal init(database: Database, vaultPath: String, dimensions: Int = 384) throws {
        self.db = database
        self.vaultPath = vaultPath
        self.dimensions = dimensions
        self.skipDimensionCheck = false
        try ensureSchema()
    }

    // MARK: - Schema Management

    /// Drop all vector tables and recreate with current dimensions. Used for full rebuild when dimensions change.
    public func resetSchema() throws {
        try dropVecTables()
        try createSchema()
    }

    private func ensureSchema() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS _vec_schema(version INTEGER, dimensions INTEGER)
        """)

        // Migration: add dimensions column if missing (upgrade from v1 schema without it)
        let colInfo = try db.query("PRAGMA table_info(_vec_schema)")
        let hasCol = colInfo.contains { $0["name"] == "dimensions" }
        if !hasCol {
            try db.execute("ALTER TABLE _vec_schema ADD COLUMN dimensions INTEGER")
        }

        let rows = try db.query("SELECT version, dimensions FROM _vec_schema LIMIT 1")
        let existingVersion = rows.first.flatMap { $0["version"] }.flatMap { Int($0) }
        let storedDimensions = rows.first.flatMap { $0["dimensions"] }.flatMap { Int($0) }

        if let v = existingVersion, v == currentVecSchemaVersion {
            // Check dimension mismatch on existing index
            if !skipDimensionCheck, let stored = storedDimensions, stored != dimensions {
                throw VectorIndexError.dimensionMismatch(stored: stored, requested: dimensions)
            }
            // Backfill dimensions if missing (upgraded from old schema)
            if storedDimensions == nil {
                try db.execute("UPDATE _vec_schema SET dimensions = \(dimensions)")
            }
            return
        }

        if existingVersion != nil {
            try dropVecTables()
        }
        try createSchema()
    }

    private func createSchema() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS _vec_schema(version INTEGER, dimensions INTEGER)
        """)

        // vec0 virtual tables don't support IF NOT EXISTS, so check manually
        let vecExists = try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='vec_chunks'")
        if vecExists.isEmpty {
            try db.createVecTable(name: "vec_chunks", dimensions: dimensions)
        }

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

        // Upsert schema version + dimensions
        let existing = try db.query("SELECT version FROM _vec_schema LIMIT 1")
        if existing.isEmpty {
            try db.execute("INSERT INTO _vec_schema(version, dimensions) VALUES (\(currentVecSchemaVersion), \(dimensions))")
        } else {
            try db.execute("UPDATE _vec_schema SET version = \(currentVecSchemaVersion), dimensions = \(dimensions)")
        }
    }

    private func dropVecTables() throws {
        try db.execute("DROP TABLE IF EXISTS vec_chunks")
        try db.execute("DROP TABLE IF EXISTS chunks")
        try db.execute("DROP TABLE IF EXISTS _vec_schema")
    }

    // MARK: - Indexing

    /// Index a single note's chunks and vectors.
    /// Vectors are normalized to unit length before storage for consistent cosine similarity scoring.
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

            // Normalize vector to unit length for proper cosine similarity with L2 distance
            let normalizedVec = Self.normalize(vectors[i])
            try db.insertVector(table: "vec_chunks", rowid: rid, vector: normalizedVec)
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

    /// Async variant of buildIndex that takes an async embedder.
    @discardableResult
    public func buildIndex(
        notes: [Note],
        asyncEmbedder: ([String]) async throws -> [[Float]],
        model: String,
        fullRebuild: Bool = false
    ) async throws -> VectorIndexStats {
        if !fullRebuild, let storedModel = try currentModel(), storedModel != model {
            throw VectorIndexError.modelMismatch(stored: storedModel, requested: model)
        }

        if fullRebuild {
            try db.execute("DELETE FROM chunks")
            try db.execute("DROP TABLE IF EXISTS vec_chunks")
            try db.createVecTable(name: "vec_chunks", dimensions: dimensions)
        }

        var notesByPath: [String: Note] = [:]
        for note in notes { notesByPath[note.relativePath] = note }

        let existingRows = try db.query("SELECT DISTINCT path, mtime FROM chunks")
        var existingMtimes: [String: Double] = [:]
        for row in existingRows {
            if let path = row["path"], let mtimeStr = row["mtime"], let mtime = Double(mtimeStr) {
                existingMtimes[path] = mtime
            }
        }

        var added = 0, updated = 0, deleted = 0

        for note in notes {
            let filePath = (vaultPath as NSString).appendingPathComponent(note.relativePath)
            let fileMtime = Self.fileMtime(atPath: filePath)

            if let existingMtime = existingMtimes[note.relativePath] {
                if abs(fileMtime - existingMtime) > 0.001 {
                    let chunks = chunkNote(note)
                    if !chunks.isEmpty {
                        let texts = chunks.map { $0.text }
                        let vectors = try await asyncEmbedder(texts)
                        try indexNote(path: note.relativePath, chunks: chunks, vectors: vectors, model: model, mtime: fileMtime)
                    }
                    updated += 1
                }
            } else {
                let chunks = chunkNote(note)
                if !chunks.isEmpty {
                    let texts = chunks.map { $0.text }
                    let vectors = try await asyncEmbedder(texts)
                    try indexNote(path: note.relativePath, chunks: chunks, vectors: vectors, model: model, mtime: fileMtime)
                }
                added += 1
            }
        }

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

    /// Default minimum cosine similarity score for vector search results.
    /// Results below this threshold are considered irrelevant and filtered out.
    /// 0.35 is a reasonable default for sentence-transformers / E5 models:
    /// - >0.7: very similar
    /// - 0.5-0.7: related
    /// - 0.35-0.5: loosely related
    /// - <0.35: likely irrelevant
    public static let defaultMinScore: Double = 0.35

    /// Search for notes matching the query vector. Returns results aggregated by note path (best chunk score per note).
    /// - Parameters:
    ///   - queryVector: The embedding vector for the search query.
    ///   - limit: Maximum number of results to return.
    ///   - minScore: Minimum cosine similarity score (0.0–1.0). Results below this are filtered out.
    public func search(queryVector: [Float], limit: Int = 10, minScore: Double = VectorIndex.defaultMinScore) throws -> [VectorSearchResult] {
        // Normalize query vector to unit length for proper cosine similarity calculation.
        // sqlite-vec uses L2² distance; for unit vectors: L2² = 2(1 - cos_sim)
        // so cos_sim = 1 - L2²/2
        let normalizedQuery = Self.normalize(queryVector)

        // Fetch more raw results than limit to allow aggregation + filtering
        let rawLimit = limit * 5
        let vecResults = try db.searchVectors(table: "vec_chunks", query: normalizedQuery, limit: rawLimit)

        guard !vecResults.isEmpty else { return [] }

        // Look up chunk metadata and aggregate by path (best score per note)
        var bestByPath: [String: VectorSearchResult] = [:]

        for result in vecResults {
            // Convert L2² distance to cosine similarity (valid for unit vectors)
            let cosineSim = max(0, 1.0 - result.distance / 2.0)

            // Skip results below minimum relevance threshold
            guard cosineSim >= minScore else { continue }

            let rows = try db.query("SELECT path, chunk_text, chunk_id FROM chunks WHERE id = \(result.rowid)")
            guard let row = rows.first,
                  let path = row["path"],
                  let chunkText = row["chunk_text"],
                  let chunkIdStr = row["chunk_id"],
                  let chunkId = Int(chunkIdStr) else { continue }

            if let existing = bestByPath[path] {
                if cosineSim > existing.score {
                    bestByPath[path] = VectorSearchResult(path: path, chunkText: chunkText, score: cosineSim, chunkId: chunkId)
                }
            } else {
                bestByPath[path] = VectorSearchResult(path: path, chunkText: chunkText, score: cosineSim, chunkId: chunkId)
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

    private func chunkNote(_ note: Note) -> [(id: Int, text: String)] {
        Chunker.chunkNote(title: note.title, body: note.body)
            .map { (id: $0.id, text: $0.text) }
    }

    /// Normalize a vector to unit length (L2 norm = 1).
    internal static func normalize(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 1e-10 else { return vector }
        return vector.map { $0 / norm }
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
