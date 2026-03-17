import Foundation

/// A vault identifier with its resolved file system path.
public struct VaultLocation: Sendable {
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// Unified search service that supports FTS, semantic, and hybrid search across vaults.
///
/// This encapsulates the search pipeline that was previously in the App layer,
/// making it reusable by both the GUI app and the CLI.
public struct VaultSearchService: Sendable {

    public enum Mode: String, Sendable {
        case text, semantic, hybrid
    }

    public enum SearchError: Error, LocalizedError {
        case noVectorIndex
        case embeddingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noVectorIndex:
                return "Build search index first (Settings → Search or `mn index`)"
            case .embeddingFailed(let detail):
                return "Embedding failed: \(detail)"
            }
        }
    }

    /// Search across one or more vaults.
    ///
    /// - Parameters:
    ///   - query: The search query string.
    ///   - mode: Search mode (text, semantic, or hybrid).
    ///   - vaults: Vault locations to search.
    ///   - embeddingProvider: Required for semantic/hybrid modes.
    ///   - limit: Maximum number of results.
    /// - Returns: Matching notes, ranked by relevance.
    public static func search(
        query: String,
        mode: Mode,
        vaults: [VaultLocation],
        embeddingProvider: (any EmbeddingProvider)? = nil,
        limit: Int = 20
    ) async throws -> [Note] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        switch mode {
        case .text:
            return ftsSearchMultiVault(query: trimmed, vaults: vaults, limit: limit)
        case .semantic:
            return try await semanticSearch(query: trimmed, vaults: vaults, provider: embeddingProvider, limit: limit)
        case .hybrid:
            return try await hybridSearch(query: trimmed, vaults: vaults, provider: embeddingProvider, limit: limit)
        }
    }

    // MARK: - FTS

    /// Full-text search across multiple vaults.
    private static func ftsSearchMultiVault(query: String, vaults: [VaultLocation], limit: Int) -> [Note] {
        var merged: [Note] = []
        for loc in vaults {
            let results = ftsSearchSingleVault(query: query, vaultPath: loc.path)
            merged.append(contentsOf: results.map { $0.withVaultName(loc.name) })
        }
        return Array(merged.prefix(limit))
    }

    /// Full-text search on a single vault.
    private static func ftsSearchSingleVault(query: String, vaultPath: String) -> [Note] {
        let vault = Vault(path: vaultPath)
        do {
            let index = try SearchIndex(vaultPath: vaultPath)
            let notes = try vault.allNotes()
            let _ = try index.buildIndex(notes: notes)
            let results = try index.search(query: query)
            return results.compactMap { result in
                notes.first { $0.relativePath == result.path }
            }
        } catch {
            Log.search.warning("FTS search failed for \(vaultPath): \(error)")
            return (try? vault.searchNotes(query: query)) ?? []
        }
    }

    /// FTS returning raw SearchResult for hybrid merge.
    private static func ftsSearchResults(query: String, vaultPath: String) -> [SearchResult] {
        let vault = Vault(path: vaultPath)
        do {
            let index = try SearchIndex(vaultPath: vaultPath)
            let notes = try vault.allNotes()
            let _ = try index.buildIndex(notes: notes)
            return try index.search(query: query)
        } catch {
            return []
        }
    }

    // MARK: - Semantic

    /// Pure semantic (vector) search across vaults.
    private static func semanticSearch(
        query: String,
        vaults: [VaultLocation],
        provider: (any EmbeddingProvider)?,
        limit: Int
    ) async throws -> [Note] {
        guard let provider else { throw SearchError.noVectorIndex }

        let hasIndex = vaults.contains { VectorIndex.vectorIndexExists(vaultPath: $0.path) }
        guard hasIndex else { throw SearchError.noVectorIndex }

        let queryVector: [Float]
        do {
            queryVector = try await provider.embedQuery(query)
        } catch {
            throw SearchError.embeddingFailed(error.localizedDescription)
        }

        var scoredNotes: [(score: Double, note: Note)] = []
        for loc in vaults {
            let vault = Vault(path: loc.path)
            guard let notes = try? vault.allNotes() else { continue }
            let vecResults = vectorSearchResults(vaultPath: loc.path, queryVector: queryVector)

            for r in vecResults {
                if let note = notes.first(where: { $0.relativePath == r.path }) {
                    scoredNotes.append((score: r.score, note: note.withVaultName(loc.name)))
                }
            }
        }

        return scoredNotes
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0.note }
    }

    // MARK: - Hybrid

    /// Hybrid search (FTS + vector with RRF fusion) across vaults.
    private static func hybridSearch(
        query: String,
        vaults: [VaultLocation],
        provider: (any EmbeddingProvider)?,
        limit: Int
    ) async throws -> [Note] {
        guard let provider else { throw SearchError.noVectorIndex }

        let hasIndex = vaults.contains { VectorIndex.vectorIndexExists(vaultPath: $0.path) }
        guard hasIndex else { throw SearchError.noVectorIndex }

        let queryVector: [Float]
        do {
            queryVector = try await provider.embedQuery(query)
        } catch {
            // Fall back to FTS on embedding failure
            Log.search.warning("Embedding failed, falling back to FTS: \(error)")
            return ftsSearchMultiVault(query: query, vaults: vaults, limit: limit)
        }

        var globalFtsResults: [SearchResult] = []
        var globalVecResults: [VectorSearchResult] = []
        var notesByPrefixedPath: [String: Note] = [:]

        for loc in vaults {
            let vault = Vault(path: loc.path)
            guard let notes = try? vault.allNotes() else { continue }

            let vaultPrefix = loc.name + "::"
            for note in notes {
                notesByPrefixedPath[vaultPrefix + note.relativePath] = note.withVaultName(loc.name)
            }

            let fts = ftsSearchResults(query: query, vaultPath: loc.path)
            for r in fts {
                globalFtsResults.append(SearchResult(
                    path: vaultPrefix + r.path,
                    title: r.title,
                    tags: r.tags,
                    snippet: r.snippet,
                    rank: r.rank
                ))
            }

            let vec = vectorSearchResults(vaultPath: loc.path, queryVector: queryVector)
            for r in vec {
                globalVecResults.append(VectorSearchResult(
                    path: vaultPrefix + r.path,
                    chunkText: r.chunkText,
                    score: r.score,
                    chunkId: r.chunkId
                ))
            }
        }

        let merged = HybridSearch.merge(
            ftsResults: globalFtsResults,
            vectorResults: globalVecResults,
            limit: limit
        )
        return merged.compactMap { notesByPrefixedPath[$0.path] }
    }

    // MARK: - Vector Helpers

    /// Vector search returning raw results for a single vault.
    private static func vectorSearchResults(vaultPath: String, queryVector: [Float]) -> [VectorSearchResult] {
        guard VectorIndex.vectorIndexExists(vaultPath: vaultPath) else { return [] }
        do {
            let dimensions = queryVector.count
            let vecIndex = try VectorIndex(vaultPath: vaultPath, dimensions: dimensions, skipDimensionCheck: true)
            return try vecIndex.search(queryVector: queryVector)
        } catch {
            return []
        }
    }
}
