import Foundation
import Observation
import MahoNotesKit

@Observable
@MainActor final class CloudSyncState {

    weak var appState: AppState?

    /// Current cloud sync mode (read from global config).
    var cloudSyncMode: CloudSyncMode = .off

    /// Whether a cloud migration is in progress.
    var isMigrating: Bool = false

    /// Status text during migration (e.g. "Migrating vaults to iCloud…").
    var migrationStatus: String?

    /// Whether the merge confirmation sheet is showing.
    var showMergeSheet: Bool = false

    /// Cloud registry found when activating sync (for merge flow).
    var pendingCloudRegistry: VaultRegistry?

    /// Summary of conflicts after a merge, for display.
    var lastMergeConflicts: [VaultNameConflict] = []

    /// Whether to show the post-merge summary.
    var showMergeResult: Bool = false

    private let store = VaultStore.shared

    nonisolated init() {}

    /// Load cloud sync mode from global config.
    func loadCloudSyncMode() {
        Task {
            let mode = await store.cloudSyncMode()
            self.cloudSyncMode = mode
        }
    }

    /// Called when user toggles cloud sync. Checks for merge needs before applying.
    func requestCloudSyncChange(to mode: CloudSyncMode) {
        Task {
            if mode == .off {
                // Turning off — migrate vaults back to local, then disable
                isMigrating = true
                migrationStatus = "Moving vaults to local storage…"
                defer { isMigrating = false; migrationStatus = nil }

                if let localRegistry = try? await store.loadRegistry() {
                    if let migrated = try? await store.migrateFromCloud(localRegistry) {
                        await applyCloudSyncMode(.off)
                        try? await store.saveRegistry(migrated)
                        await appState?.loadRegistryAsync()
                        return
                    }
                }
                await applyCloudSyncMode(.off)
                return
            }

            // Turning on — check if iCloud already has a registry
            isMigrating = true
            migrationStatus = "Checking iCloud…"

            let check = await store.checkCloudRegistryExists()
            switch check {
            case .noCloudRegistry:
                // No conflict — activate, migrate vaults to iCloud, and save
                migrationStatus = "Migrating vaults to iCloud…"
                await applyCloudSyncMode(.icloud)
                if var localRegistry = try? await store.loadRegistry() {
                    if let migrated = try? await store.migrateToCloud(localRegistry) {
                        localRegistry = migrated
                    }
                    try? await store.saveRegistry(localRegistry)
                    await appState?.loadRegistryAsync()
                }
                isMigrating = false
                migrationStatus = nil
            case .cloudRegistryExists(let cloudRegistry):
                // Need merge — show confirmation
                isMigrating = false
                migrationStatus = nil
                pendingCloudRegistry = cloudRegistry
                showMergeSheet = true
            }
        }
    }

    /// Merge local vaults with cloud registry.
    func performMerge() {
        Task {
            isMigrating = true
            migrationStatus = "Merging vaults…"
            defer { isMigrating = false; migrationStatus = nil }

            // Load local registry BEFORE switching mode (same reason as replaceCloudWithLocal)
            let localRegistrySnapshot: VaultRegistry?
            do {
                localRegistrySnapshot = try await store.loadRegistry()
            } catch {
                localRegistrySnapshot = nil
            }

            guard let cloudRegistry = pendingCloudRegistry,
                  let localRegistry = localRegistrySnapshot ?? VaultRegistry(primary: "default", vaults: [])
                  as VaultRegistry?
            else {
                pendingCloudRegistry = nil
                showMergeSheet = false
                return
            }

            var (merged, conflicts) = await store.mergeRegistries(local: localRegistry, cloud: cloudRegistry)

            // Activate cloud sync, then migrate device vaults to iCloud and save
            migrationStatus = "Migrating vaults to iCloud…"
            await applyCloudSyncMode(.icloud)
            if let migrated = try? await store.migrateToCloud(merged) {
                merged = migrated
            }
            try? await store.saveRegistry(merged)

            // Update local state directly (avoid loadRegistry re-reading before iCloud propagates)
            appState?.updateRegistryState(vaults: merged.vaults, primaryVaultName: merged.primary)
            self.lastMergeConflicts = conflicts
            self.pendingCloudRegistry = nil
            self.showMergeSheet = false

            // Now reload to pick up resolved paths
            await appState?.loadRegistryAsync()

            if !conflicts.isEmpty {
                self.showMergeResult = true
            }
        }
    }

    /// Replace cloud registry with local registry (discard cloud).
    func replaceCloudWithLocal() {
        Task {
            isMigrating = true
            migrationStatus = "Migrating vaults to iCloud…"
            defer { isMigrating = false; migrationStatus = nil }

            // Load local registry BEFORE switching to iCloud mode
            // (otherwise loadRegistry reads from iCloud and gets the cloud registry)
            let localRegistrySnapshot: VaultRegistry?
            do {
                localRegistrySnapshot = try await store.loadRegistry()
            } catch {
                localRegistrySnapshot = nil
            }

            await applyCloudSyncMode(.icloud)

            if var registry = localRegistrySnapshot {
                if let migrated = try? await store.migrateToCloud(registry) {
                    registry = migrated
                }
                try? await store.saveRegistry(registry)
            }

            pendingCloudRegistry = nil
            showMergeSheet = false
            await appState?.loadRegistryAsync()
        }
    }

    /// Cancel merge — don't turn on cloud sync.
    func cancelMerge() {
        pendingCloudRegistry = nil
        showMergeSheet = false
    }

    /// Internal: persist cloud sync mode.
    private func applyCloudSyncMode(_ mode: CloudSyncMode) async {
        do {
            try await store.setCloudSyncMode(mode)
            self.cloudSyncMode = mode
        } catch {
            let current = await store.cloudSyncMode()
            self.cloudSyncMode = current
        }
    }
}
