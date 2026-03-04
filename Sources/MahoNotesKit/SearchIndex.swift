import Foundation
import CJKSQLite

/// Statistics from an index build operation.
public struct IndexStats: Sendable {
    public let added: Int
    public let updated: Int
    public let deleted: Int
    public let total: Int
}

/// A single search result with ranking info.
public struct SearchResult: Sendable {
    public let path: String
    public let title: String
    public let tags: [String]
    public let snippet: String
    public let rank: Double
}

/// Errors specific to SearchIndex operations.
public enum SearchIndexError: Error, LocalizedError {
    case indexCorrupt(message: String)
    case queryFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case .indexCorrupt(let msg): return "Search index corrupt: \(msg)"
        case .queryFailed(let msg): return "Search query failed: \(msg)"
        }
    }
}

private let currentSchemaVersion = 1

/// Full-text search index backed by SQLite FTS5 with CJK tokenizer.
public final class SearchIndex: @unchecked Sendable {
    private let db: Database
    private let vaultPath: String

    /// Open or create the search index at `.maho/index.db` inside the vault.
    public init(vaultPath: String) throws {
        self.vaultPath = (vaultPath as NSString).expandingTildeInPath
        let mahoDir = (self.vaultPath as NSString).appendingPathComponent(".maho")
        let fm = FileManager.default

        if !fm.fileExists(atPath: mahoDir) {
            try fm.createDirectory(atPath: mahoDir, withIntermediateDirectories: true)
        }

        let dbPath = (mahoDir as NSString).appendingPathComponent("index.db")

        // Try to open; if corrupt, delete and retry
        do {
            self.db = try Database(path: dbPath)
        } catch {
            // Remove corrupt DB and retry once
            try? fm.removeItem(atPath: dbPath)
            self.db = try Database(path: dbPath)
        }

        try ensureSchema()
    }

    /// Initialize with an explicit Database instance (for testing).
    internal init(database: Database, vaultPath: String) throws {
        self.db = database
        self.vaultPath = vaultPath
        try ensureSchema()
    }

    // MARK: - Schema Management

    private func ensureSchema() throws {
        // Create schema version table
        try db.execute("""
            CREATE TABLE IF NOT EXISTS _schema(version INTEGER)
        """)

        let rows = try db.query("SELECT version FROM _schema LIMIT 1")
        let existingVersion = rows.first.flatMap { $0["version"] }.flatMap { Int($0) }

        if let v = existingVersion, v == currentSchemaVersion {
            // Schema is current, nothing to do
            return
        }

        if existingVersion != nil {
            // Version mismatch — drop everything and recreate
            try dropAllTables()
            try db.execute("CREATE TABLE IF NOT EXISTS _schema(version INTEGER)")
        }

        // Create tables
        try db.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
                path, title, tags, body,
                tokenize='cjk'
            )
        """)

        try db.execute("""
            CREATE TABLE IF NOT EXISTS _meta(
                path TEXT PRIMARY KEY,
                mtime REAL,
                indexed_at REAL
            )
        """)

        // Set schema version
        if existingVersion == nil {
            try db.execute("INSERT INTO _schema(version) VALUES (\(currentSchemaVersion))")
        } else {
            try db.execute("UPDATE _schema SET version = \(currentSchemaVersion)")
        }
    }

    private func dropAllTables() throws {
        try db.execute("DROP TABLE IF EXISTS notes_fts")
        try db.execute("DROP TABLE IF EXISTS _meta")
        try db.execute("DROP TABLE IF EXISTS _schema")
    }

    // MARK: - Indexing

    /// Build or update the FTS5 index from the given notes.
    /// - Parameters:
    ///   - notes: All notes currently in the vault.
    ///   - fullRebuild: If true, drop and recreate the entire index.
    /// - Returns: Statistics about what changed.
    @discardableResult
    public func buildIndex(notes: [Note], fullRebuild: Bool = false) throws -> IndexStats {
        if fullRebuild {
            try db.execute("DELETE FROM notes_fts")
            try db.execute("DELETE FROM _meta")
        }

        let now = Date().timeIntervalSince1970

        // Build a map of current notes by relative path
        var notesByPath: [String: Note] = [:]
        for note in notes {
            notesByPath[note.relativePath] = note
        }

        // Get existing indexed paths
        let existingRows = try db.query("SELECT path, mtime FROM _meta")
        var existingMtimes: [String: Double] = [:]
        for row in existingRows {
            if let path = row["path"], let mtimeStr = row["mtime"], let mtime = Double(mtimeStr) {
                existingMtimes[path] = mtime
            }
        }

        var added = 0
        var updated = 0
        var deleted = 0

        // Insert/update notes
        for note in notes {
            let filePath = (vaultPath as NSString).appendingPathComponent(note.relativePath)
            let fileMtime = Self.fileMtime(atPath: filePath)
            let tagsJoined = note.tags.joined(separator: " ")

            if let existingMtime = existingMtimes[note.relativePath] {
                // Note exists in index — check if changed
                if fileMtime > existingMtime {
                    // Update: delete old, insert new
                    try deleteFromIndex(path: note.relativePath)
                    try insertIntoIndex(path: note.relativePath, title: note.title, tags: tagsJoined, body: note.body)
                    try updateMeta(path: note.relativePath, mtime: fileMtime, indexedAt: now)
                    updated += 1
                }
                // else: unchanged, skip
            } else {
                // New note — insert
                try insertIntoIndex(path: note.relativePath, title: note.title, tags: tagsJoined, body: note.body)
                try insertMeta(path: note.relativePath, mtime: fileMtime, indexedAt: now)
                added += 1
            }
        }

        // Prune deleted notes
        let currentPaths = Set(notesByPath.keys)
        for existingPath in existingMtimes.keys {
            if !currentPaths.contains(existingPath) {
                try deleteFromIndex(path: existingPath)
                try deleteMeta(path: existingPath)
                deleted += 1
            }
        }

        return IndexStats(added: added, updated: updated, deleted: deleted, total: notes.count)
    }

    // MARK: - Search

    /// Search the FTS5 index for the given query.
    /// - Returns: Ranked results (best match first).
    public func search(query: String) throws -> [SearchResult] {
        let escaped = escapeFTS5Query(query)
        guard !escaped.isEmpty else { return [] }

        // Try FTS5 MATCH first
        let ftsResults = try ftsMatch(escaped, query: query)
        if !ftsResults.isEmpty { return ftsResults }

        // Fallback: NLTokenizer may segment the query differently than the indexed text
        // (e.g., "微中子" as standalone gets split into "微"+"中子" but was indexed as one token).
        // Use a SQL LIKE fallback on the FTS5 content columns for CJK robustness.
        return try likeFallback(query: query)
    }

    private func ftsMatch(_ escaped: String, query: String) throws -> [SearchResult] {
        let escapedForSQL = escaped.replacingOccurrences(of: "'", with: "''")
        let sql = """
            SELECT path, title, tags, body,
                   bm25(notes_fts, 0.0, 10.0, 5.0, 1.0) as rank
            FROM notes_fts
            WHERE notes_fts MATCH '\(escapedForSQL)'
            ORDER BY rank
        """

        let rows = try db.query(sql)
        return rows.map { row in
            parseSearchRow(row, query: query)
        }
    }

    private func likeFallback(query: String) throws -> [SearchResult] {
        let likeQ = query.replacingOccurrences(of: "'", with: "''")
        let sql = """
            SELECT path, title, tags, body, 0.0 as rank
            FROM notes_fts
            WHERE title LIKE '%\(likeQ)%'
               OR tags LIKE '%\(likeQ)%'
               OR body LIKE '%\(likeQ)%'
        """

        let rows = try db.query(sql)
        return rows.map { row in
            parseSearchRow(row, query: query)
        }
    }

    private func parseSearchRow(_ row: [String: String], query: String) -> SearchResult {
        let path = row["path"] ?? ""
        let title = row["title"] ?? ""
        let tagsStr = row["tags"] ?? ""
        let body = row["body"] ?? ""
        let rank = Double(row["rank"] ?? "0") ?? 0.0
        let tags = tagsStr.isEmpty ? [] : tagsStr.components(separatedBy: " ").filter { !$0.isEmpty }
        let snippet = extractSnippet(from: body, query: query)
        return SearchResult(path: path, title: title, tags: tags, snippet: snippet, rank: rank)
    }

    /// Check whether the index database file exists.
    public static func indexExists(vaultPath: String) -> Bool {
        let expanded = (vaultPath as NSString).expandingTildeInPath
        let dbPath = (expanded as NSString).appendingPathComponent(".maho/index.db")
        return FileManager.default.fileExists(atPath: dbPath)
    }

    // MARK: - Helpers

    private func insertIntoIndex(path: String, title: String, tags: String, body: String) throws {
        let p = escapeSQLString(path)
        let t = escapeSQLString(title)
        let tg = escapeSQLString(tags)
        let b = escapeSQLString(body)
        try db.execute("INSERT INTO notes_fts(path, title, tags, body) VALUES ('\(p)', '\(t)', '\(tg)', '\(b)')")
    }

    private func deleteFromIndex(path: String) throws {
        let p = escapeSQLString(path)
        try db.execute("DELETE FROM notes_fts WHERE path = '\(p)'")
    }

    private func insertMeta(path: String, mtime: Double, indexedAt: Double) throws {
        let p = escapeSQLString(path)
        try db.execute("INSERT INTO _meta(path, mtime, indexed_at) VALUES ('\(p)', \(mtime), \(indexedAt))")
    }

    private func updateMeta(path: String, mtime: Double, indexedAt: Double) throws {
        let p = escapeSQLString(path)
        try db.execute("UPDATE _meta SET mtime = \(mtime), indexed_at = \(indexedAt) WHERE path = '\(p)'")
    }

    private func deleteMeta(path: String) throws {
        let p = escapeSQLString(path)
        try db.execute("DELETE FROM _meta WHERE path = '\(p)'")
    }

    private func escapeSQLString(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }

    private func escapeFTS5Query(_ query: String) -> String {
        // Clean up the query for safe FTS5 MATCH usage.
        // Remove FTS5 special characters that could cause syntax errors,
        // but don't wrap in quotes (which would force exact phrase tokenization
        // and break CJK search where NLTokenizer segments differently).
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // Remove characters that have special meaning in FTS5 query syntax
        let cleaned = trimmed
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "^", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned
    }

    private func extractSnippet(from body: String, query: String) -> String {
        let lines = body.components(separatedBy: "\n")
        let queryLower = query.lowercased()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && trimmed.lowercased().contains(queryLower) {
                return String(trimmed.prefix(120))
            }
        }
        // Return first non-empty line as fallback
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                return String(trimmed.prefix(120))
            }
        }
        return ""
    }

    private static func fileMtime(atPath path: String) -> Double {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else {
            return 0
        }
        return date.timeIntervalSince1970
    }
}
