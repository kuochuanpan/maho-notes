import Foundation
import Observation
import MahoNotesKit

/// Central app state — loads vault registry, resolves vault paths, tracks selection.
@Observable
final class AppState {

    // MARK: - Published State

    /// All registered vaults from the vault registry.
    private(set) var vaults: [VaultEntry] = []

    /// The currently selected vault name.
    var selectedVaultName: String?

    /// Error message if vault registry failed to load.
    private(set) var errorMessage: String?

    /// Whether the initial load has completed.
    private(set) var isLoaded: Bool = false

    // MARK: - Computed

    /// The currently selected vault entry.
    var selectedVault: VaultEntry? {
        guard let name = selectedVaultName else { return nil }
        return vaults.first { $0.name == name }
    }

    /// The primary vault name from the registry.
    private(set) var primaryVaultName: String?

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
                    selectedVaultName = registry.primary ?? registry.vaults.first?.name
                }
            } else {
                // No registry found — not an error, just empty
                self.vaults = []
                self.primaryVaultName = nil
            }

            self.errorMessage = nil
            self.isLoaded = true
        } catch {
            self.errorMessage = "Failed to load vault registry: \(error.localizedDescription)"
            self.vaults = []
            self.isLoaded = true
        }
    }

    /// Reload the vault registry (e.g., after iCloud sync changes).
    @MainActor
    func reloadRegistry() {
        loadRegistry()
    }
}
