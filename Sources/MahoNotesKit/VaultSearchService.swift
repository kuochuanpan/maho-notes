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

    /// Full-text search across multiple vaults with global BM25 ranking.
    private static func ftsSearchMultiVault(query: String, vaults: [VaultLocation], limit: Int) -> [Note] {
        var scoredNotes: [(rank: Double, note: Note)] = []
        for loc in vaults {
            let vault = Vault(path: loc.path)
            do {
                let index = try SearchIndex(vaultPath: loc.path)
                let notes = try vault.allNotes()
                let _ = try index.buildIndex(notes: notes)
                let results = try index.search(query: query)
                let notesByPath = Dictionary(uniqueKeysWithValues: notes.map { ($0.relativePath, $0) })
                for r in results {
                    if let note = notesByPath[r.path] {
                        scoredNotes.append((rank: r.rank, note: note.withVaultName(loc.name)))
                    }
                }
            } catch {
                Log.search.warning("FTS search failed for \(loc.path): \(error)")
                if let fallback = try? vault.searchNotes(query: query) {
                    scoredNotes.append(contentsOf: fallback.map { (rank: 0.0, note: $0.withVaultName(loc.name)) })
                }
            }
        }
        // BM25 returns negative scores where more negative = better match
        return scoredNotes
            .sorted { $0.rank < $1.rank }
            .prefix(limit)
            .map { $0.note }
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

    /// Pure semantic (vector) search across vaults with global cosine similarity ranking.
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

        // Collect results from ALL vaults with scores, then globally rank
        var scoredNotes: [(score: Double, note: Note)] = []
        for loc in vaults {
            let vault = Vault(path: loc.path)
            guard let notes = try? vault.allNotes() else { continue }
            let notesByPath = Dictionary(uniqueKeysWithValues: notes.map { ($0.relativePath, $0) })
            // Fetch more per vault to ensure good global coverage
            let vecResults = vectorSearchResults(vaultPath: loc.path, queryVector: queryVector, limit: limit * 3)

            for r in vecResults {
                if let note = notesByPath[r.path] {
                    scoredNotes.append((score: r.score, note: note.withVaultName(loc.name)))
                }
            }
        }

        // Global sort by cosine similarity — best matches across all vaults rise to top
        return scoredNotes
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0.note }
    }

    // MARK: - Hybrid

    /// Hybrid search (FTS + vector with RRF fusion) across vaults.
    ///
    /// Quality strategy:
    /// 1. Collect FTS and vector results from all vaults
    /// 2. Global-sort each list by quality (BM25 rank / cosine similarity)
    /// 3. Truncate each to top candidates before RRF merge (prevents low-quality noise)
    /// 4. RRF merge with global rankings
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

            let vec = vectorSearchResults(vaultPath: loc.path, queryVector: queryVector, limit: limit * 3)
            for r in vec {
                globalVecResults.append(VectorSearchResult(
                    path: vaultPrefix + r.path,
                    chunkText: r.chunkText,
                    score: r.score,
                    chunkId: r.chunkId
                ))
            }
        }

        // Global sort before RRF: rank by actual quality scores, not per-vault order
        // BM25: more negative = better match
        let rrfCandidateLimit = limit * 3
        let sortedFts = globalFtsResults
            .sorted { $0.rank < $1.rank }
            .prefix(rrfCandidateLimit)
            .map { $0 }
        // Vector: higher cosine similarity = better match
        let sortedVec = globalVecResults
            .sorted { $0.score > $1.score }
            .prefix(rrfCandidateLimit)
            .map { $0 }

        let merged = HybridSearch.merge(
            ftsResults: Array(sortedFts),
            vectorResults: Array(sortedVec),
            limit: limit
        )
        return merged.compactMap { notesByPrefixedPath[$0.path] }
    }

    // MARK: - Vector Helpers

    /// Vector search returning raw results for a single vault.
    private static func vectorSearchResults(vaultPath: String, queryVector: [Float], limit: Int = 10) -> [VectorSearchResult] {
        guard VectorIndex.vectorIndexExists(vaultPath: vaultPath) else { return [] }
        do {
            let dimensions = queryVector.count
            let vecIndex = try VectorIndex(vaultPath: vaultPath, dimensions: dimensions, skipDimensionCheck: true)
            return try vecIndex.search(queryVector: queryVector, limit: limit)
        } catch {
            return []
        }
    }
}
