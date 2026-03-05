import Foundation
import Observation
import MahoNotesKit

/// Central app state — loads vault registry, resolves vault paths, tracks selection.
@Observable
final class AppState {

    // MARK: - Vault Registry

    /// All registered vaults from the vault registry.
    private(set) var vaults: [VaultEntry] = []

    /// The currently selected vault name.
    var selectedVaultName: String?

    /// Error message if vault registry failed to load.
    private(set) var errorMessage: String?

    /// Whether the initial load has completed.
    private(set) var isLoaded: Bool = false

    /// The primary vault name from the registry.
    private(set) var primaryVaultName: String?

    // MARK: - Vault Content

    /// Collections in the currently selected vault.
    private(set) var collections: [Collection] = []

    /// All notes in the currently selected vault, grouped by collection.
    private(set) var notesByCollection: [String: [Note]] = [:]

    /// Recent notes (last 10 by updated date).
    var recentNotes: [Note] {
        allNotes
            .sorted { $0.updated > $1.updated }
            .prefix(10)
            .map { $0 }
    }

    /// All notes flat list.
    private(set) var allNotes: [Note] = []

    // MARK: - Note Selection

    /// Relative path of the currently selected note.
    var selectedNotePath: String?

    /// The currently selected note (loaded on demand).
    var selectedNote: Note? {
        guard let path = selectedNotePath else { return nil }
        return allNotes.first { $0.relativePath == path }
    }

    // MARK: - Computed

    /// The currently selected vault entry.
    var selectedVault: VaultEntry? {
        guard let name = selectedVaultName else { return nil }
        return vaults.first { $0.name == name }
    }

    /// Vaults grouped by type for the rail.
    var icloudVaults: [VaultEntry] { vaults.filter { $0.type == .icloud } }
    var githubVaults: [VaultEntry] { vaults.filter { $0.type == .github } }
    var localVaults: [VaultEntry] { vaults.filter { $0.type == .local } }

    // MARK: - Init

    init() {}

    // MARK: - Loading

    /// Load the vault registry. Call on app launch.
    @MainActor
    func loadRegistry() {
        do {
            let result: VaultRegistry? = try MahoNotesKit.loadRegistry()

            if let registry = result {
                self.vaults = registry.vaults
                self.primaryVaultName = registry.primary

                // Auto-select primary vault if nothing selected
                if selectedVaultName == nil {
                    selectedVaultName = registry.primary
                }
            } else {
                self.vaults = []
                self.primaryVaultName = nil
            }

            self.errorMessage = nil
            self.isLoaded = true
            loadSelectedVault()
        } catch {
            self.errorMessage = "Failed to load vault registry: \(error.localizedDescription)"
            self.vaults = []
            self.isLoaded = true
        }
    }

    /// Reload the vault registry.
    @MainActor
    func reloadRegistry() {
        loadRegistry()
    }

    /// Load collections and notes for the currently selected vault.
    @MainActor
    func loadSelectedVault() {
        guard let entry = selectedVault else {
            collections = []
            notesByCollection = [:]
            allNotes = []
            selectedNotePath = nil
            return
        }

        let vaultPath = resolvedPath(for: entry)
        let vault = Vault(path: vaultPath)

        do {
            self.collections = try vault.collections()
            self.allNotes = try vault.allNotes()

            var grouped: [String: [Note]] = [:]
            for note in allNotes {
                grouped[note.collection, default: []].append(note)
            }
            // Sort notes within each collection by title
            for key in grouped.keys {
                grouped[key]?.sort { $0.title < $1.title }
            }
            self.notesByCollection = grouped
        } catch {
            self.collections = []
            self.allNotes = []
            self.notesByCollection = [:]
        }

        selectedNotePath = nil
    }

    /// Notes for a given collection id.
    func notes(for collectionId: String) -> [Note] {
        notesByCollection[collectionId] ?? []
    }
}
