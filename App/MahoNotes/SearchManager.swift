import Foundation
import Observation
import MahoNotesKit

@Observable
@MainActor final class SearchManager {

    weak var appState: AppState?

    /// Whether the search panel is visible.
    var showSearchPanel: Bool = false

    /// Current search query text.
    var searchQuery: String = ""

    /// Search results from FTS.
    private(set) var searchResults: [Note] = []

    /// Search mode: "text", "semantic", or "hybrid".
    var searchMode: String {
        get { UserDefaults.standard.string(forKey: "searchMode") ?? "text" }
        set { UserDefaults.standard.set(newValue, forKey: "searchMode") }
    }

    /// Search scope: "thisVault" or "allVaults".
    var searchScope: String {
        get { UserDefaults.standard.string(forKey: "searchScope") ?? "thisVault" }
        set { UserDefaults.standard.set(newValue, forKey: "searchScope") }
    }

    /// Embedding model identifier: "minilm", "e5-small", or "e5-large".
    var embeddingModel: String {
        get { UserDefaults.standard.string(forKey: "embeddingModel") ?? "minilm" }
        set { UserDefaults.standard.set(newValue, forKey: "embeddingModel") }
    }

    /// Error message from search (e.g., vector index not built).
    private(set) var searchError: String?

    /// Whether a search index build is in progress.
    var isIndexBuilding: Bool = false

    /// Embedding provider (lazy-loaded, reused across searches).
    private var embeddingProvider: (any EmbeddingProvider)?

    nonisolated init() {}

    /// Toggle search panel visibility.
    func toggleSearch() {
        showSearchPanel.toggle()
        if showSearchPanel {
            // Focus the title bar search field
            #if os(macOS)
            NotificationCenter.default.post(name: .focusTitleBarSearch, object: nil)
            #endif
        } else {
            searchQuery = ""
            searchResults = []
            searchError = nil
        }
    }

    /// Get or create the embedding provider for the current model setting.
    private func getEmbeddingProvider() -> any EmbeddingProvider {
        if let provider = embeddingProvider, provider.modelIdentifier == embeddingModel {
            return provider
        }
        let model = EmbeddingModel(rawValue: embeddingModel) ?? .minilm
        let provider = SwiftEmbeddingsProvider(model: model)
        embeddingProvider = provider
        return provider
    }

    /// Perform search (async — supports FTS, semantic, and hybrid modes).
    func performSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = []
            searchError = nil
            return
        }

        let mode = searchMode
        if mode == "text" {
            // Synchronous FTS — no async needed
            performFTSSearch(query: query)
        } else {
            // Semantic or Hybrid — need async embedding
            Task {
                await performAsyncSearch(query: query, mode: mode)
            }
        }
    }

    /// Synchronous FTS-only search.
    private func performFTSSearch(query: String) {
        guard let appState else { return }
        let store = appState.store
        searchError = nil
        if searchScope == "allVaults" {
            var merged: [Note] = []
            for entry in appState.vaults {
                merged.append(contentsOf: ftsSearch(entry: entry, store: store, query: query))
            }
            searchResults = Array(merged.prefix(20))
        } else if let entry = appState.selectedVault {
            searchResults = Array(ftsSearch(entry: entry, store: store, query: query).prefix(20))
        } else {
            searchResults = []
        }
    }

    /// Async search for semantic and hybrid modes.
    private func performAsyncSearch(query: String, mode: String) async {
        guard let appState else { return }
        let store = appState.store
        let vaults = appState.vaults
        let entries = searchScope == "allVaults" ? vaults : (appState.selectedVault.map { [$0] } ?? [])

        // Check vector index exists for at least one vault
        let hasVectorIndex = entries.contains { VectorIndex.vectorIndexExists(vaultPath: store.resolvedPath(for: $0)) }
        guard hasVectorIndex else {
            searchError = "Build search index first (Settings \u{2192} Search or `mn index`)"
            searchResults = []
            return
        }

        searchError = nil

        // Embed the query
        let provider = getEmbeddingProvider()
        let queryVector: [Float]
        do {
            queryVector = try await provider.embed(query)
        } catch {
            searchError = "Embedding failed: \(error.localizedDescription)"
            performFTSSearch(query: query)
            return
        }

        // For cross-vault search: collect ALL results across vaults, then rank globally.
        // This prevents per-vault "top result" pollution — a vault with irrelevant
        // content won't show up just because something is its "best match."

        // Semantic: collect (score, Note) pairs, sort globally by cosine similarity
        var scoredNotes: [(score: Double, note: Note)] = []

        // Hybrid: collect raw FTS + vector results across vaults with vault-prefixed paths,
        // then do ONE global RRF merge to get fair cross-vault ranking.
        var globalFtsResults: [SearchResult] = []
        var globalVecResults: [VectorSearchResult] = []
        var notesByPrefixedPath: [String: Note] = [:]

        for entry in entries {
            let vaultPath = store.resolvedPath(for: entry)
            let vault = Vault(path: vaultPath)
            let notes: [Note]
            do {
                notes = try vault.allNotes()
            } catch {
                continue
            }

            let vecResults = vectorSearchResults(vaultPath: vaultPath, queryVector: queryVector)

            if mode == "semantic" {
                // Map vector results -> Note with score
                for r in vecResults {
                    if let note = notes.first(where: { $0.relativePath == r.path }) {
                        scoredNotes.append((score: r.score, note: note))
                    }
                }
            } else {
                // Hybrid: prefix paths with vault name to avoid collision across vaults
                let vaultPrefix = entry.name + "::"
                for note in notes {
                    notesByPrefixedPath[vaultPrefix + note.relativePath] = note
                }

                // Collect FTS results with prefixed paths
                let ftsResults = ftsSearchResults(entry: entry, store: store, query: query)
                for r in ftsResults {
                    globalFtsResults.append(SearchResult(
                        path: vaultPrefix + r.path,
                        title: r.title,
                        tags: r.tags,
                        snippet: r.snippet,
                        rank: r.rank
                    ))
                }
                // Collect vector results with prefixed paths
                for r in vecResults {
                    globalVecResults.append(VectorSearchResult(
                        path: vaultPrefix + r.path,
                        chunkText: r.chunkText,
                        score: r.score,
                        chunkId: r.chunkId
                    ))
                }
            }
        }

        if mode == "semantic" {
            // Sort globally by cosine similarity — absolute scores are comparable across vaults
            searchResults = scoredNotes
                .sorted { $0.score > $1.score }
                .prefix(20)
                .map { $0.note }
        } else {
            // Global RRF merge: one ranking across all vaults
            let merged = HybridSearch.merge(
                ftsResults: globalFtsResults,
                vectorResults: globalVecResults,
                limit: 20
            )
            searchResults = merged.compactMap { notesByPrefixedPath[$0.path] }
        }
    }

    /// FTS search returning Note objects for a single vault.
    private func ftsSearch(entry: VaultEntry, store: VaultStore, query: String) -> [Note] {
        let vaultPath = store.resolvedPath(for: entry)
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
            return (try? vault.searchNotes(query: query)) ?? []
        }
    }

    /// FTS search returning raw SearchResult (for hybrid merge).
    private func ftsSearchResults(entry: VaultEntry, store: VaultStore, query: String) -> [SearchResult] {
        let vaultPath = store.resolvedPath(for: entry)
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

    /// Vector search returning Note objects.
    private func vectorSearch(vaultPath: String, queryVector: [Float], notes: [Note]) -> [Note] {
        let results = vectorSearchResults(vaultPath: vaultPath, queryVector: queryVector)
        return results.compactMap { result in
            notes.first { $0.relativePath == result.path }
        }
    }

    /// Vector search returning raw VectorSearchResult (for hybrid merge).
    private func vectorSearchResults(vaultPath: String, queryVector: [Float]) -> [VectorSearchResult] {
        guard VectorIndex.vectorIndexExists(vaultPath: vaultPath) else { return [] }
        do {
            let dimensions = queryVector.count
            let vecIndex = try VectorIndex(vaultPath: vaultPath, dimensions: dimensions, skipDimensionCheck: true)
            return try vecIndex.search(queryVector: queryVector)
        } catch {
            return []
        }
    }

    /// Clear the search query and results.
    func clearSearch() {
        searchQuery = ""
        searchResults = []
        searchError = nil
    }

    /// Select a note from search results and dismiss the panel.
    func selectSearchResult(_ note: Note) {
        appState?.selectedNotePath = note.relativePath
        appState?.navigatorSelection = [note.relativePath]
        showSearchPanel = false
        searchQuery = ""
        searchResults = []
        searchError = nil
    }

    /// Check if vector index exists for a given vault path.
    func vectorIndexExists(for vaultPath: String) -> Bool {
        VectorIndex.vectorIndexExists(vaultPath: vaultPath)
    }
}
