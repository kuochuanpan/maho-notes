import Foundation
import Observation
import MahoNotesKit

/// App-layer search state manager.
///
/// Owns UI state (query, results, panel visibility, settings) and delegates
/// the actual search pipeline to `VaultSearchService` in MahoNotesKit.
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
    /// Public access for iOS views that run search independently.
    func embeddingProviderForSearch() -> any EmbeddingProvider {
        getEmbeddingProvider()
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

    /// Resolve vault locations for the current search scope.
    private func resolveVaultLocations() -> [VaultLocation] {
        guard let appState else { return [] }
        let store = appState.store
        let entries: [VaultEntry]
        if searchScope == "allVaults" {
            entries = appState.vaults
        } else if let entry = appState.selectedVault {
            entries = [entry]
        } else {
            return []
        }
        return entries.map { VaultLocation(name: $0.name, path: store.resolvedPath(for: $0)) }
    }

    /// Perform search (async — supports FTS, semantic, and hybrid modes).
    func performSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = []
            searchError = nil
            return
        }

        let mode = VaultSearchService.Mode(rawValue: searchMode) ?? .text
        let locations = resolveVaultLocations()
        guard !locations.isEmpty else {
            searchResults = []
            return
        }

        if mode == .text {
            // Synchronous FTS
            searchError = nil
            Task {
                do {
                    searchResults = try await VaultSearchService.search(
                        query: query, mode: .text, vaults: locations, limit: 20
                    )
                } catch {
                    searchError = error.localizedDescription
                }
            }
        } else {
            Task {
                do {
                    let provider = getEmbeddingProvider()
                    searchResults = try await VaultSearchService.search(
                        query: query, mode: mode, vaults: locations,
                        embeddingProvider: provider, limit: 20
                    )
                    searchError = nil
                } catch {
                    searchError = error.localizedDescription
                    // Fall back to FTS on semantic/hybrid failure
                    if let ftsResults = try? await VaultSearchService.search(
                        query: query, mode: .text, vaults: locations, limit: 20
                    ) {
                        searchResults = ftsResults
                    }
                }
            }
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
        showSearchPanel = false
        searchQuery = ""
        searchResults = []
        searchError = nil

        // If the result is from a different vault, switch vault first
        if let vaultName = note.vaultName,
           let appState,
           appState.selectedVaultName != vaultName {
            appState.selectedVaultName = vaultName
            // Delay note selection until vault switch completes (onChange triggers loadSelectedVault)
            let path = note.relativePath
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                appState.selectedNotePath = path
                appState.navigatorSelection = [path]
            }
        } else {
            appState?.selectedNotePath = note.relativePath
            appState?.navigatorSelection = [note.relativePath]
        }
    }

    /// Check if vector index exists for a given vault path.
    func vectorIndexExists(for vaultPath: String) -> Bool {
        VectorIndex.vectorIndexExists(vaultPath: vaultPath)
    }
}
