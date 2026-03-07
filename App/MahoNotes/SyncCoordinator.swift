import Foundation
import Observation
import MahoNotesKit

// MARK: - VaultSyncStatus

struct VaultSyncStatus {
    var isSyncing: Bool = false
    var lastSyncDate: Date?
    var lastError: String?
}

// MARK: - SyncCoordinator

/// Manages GitHub sync lifecycle for all vaults that have a `github` remote.
///
/// - Periodic pull every 5 minutes.
/// - Debounced push (30 s) after content changes.
/// - Manual full sync via ``syncNow()``.
@Observable
final class SyncCoordinator: @unchecked Sendable {

    // MARK: - Observable State

    var isSyncing: Bool = false
    var lastSyncDate: Date?
    var lastSyncError: String?
    var vaultSyncStatus: [String: VaultSyncStatus] = [:]

    // MARK: - Private State

    private var managers: [String: GitHubSyncManager] = [:]
    private var periodicTask: Task<Void, Never>?
    private var debounceTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Lifecycle

    /// Resolve a GitHub auth token off-actor (may spawn a subprocess on macOS).
    private nonisolated static func resolveToken() -> String? {
        try? Auth().resolveToken().token
    }

    /// Start sync for all vaults that have a `github` field, resolving the auth token
    /// automatically via the standard priority chain (env → gh CLI → config).
    @MainActor
    func startResolving(vaults: [VaultEntry]) {
        let githubVaults = vaults.filter { $0.github != nil }
        guard !githubVaults.isEmpty else { return }

        Task { @MainActor [weak self] in
            // Resolve token off-actor to avoid blocking if gh CLI subprocess is involved
            let token = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                Task.detached(priority: .background) {
                    continuation.resume(returning: Self.resolveToken())
                }
            }
            guard let token else { return }
            self?.start(vaults: githubVaults, token: token)
        }
    }

    /// Start sync with an explicit token.
    @MainActor
    func start(vaults: [VaultEntry], token: String) {
        stop()

        for entry in vaults {
            guard let ownerRepo = entry.github else { continue }
            let vaultPath = resolvedPath(for: entry)
            guard let manager = GitHubSyncManager.make(
                ownerRepo: ownerRepo,
                branch: "main",
                vaultPath: vaultPath,
                token: token
            ) else { continue }
            managers[entry.name] = manager
            vaultSyncStatus[entry.name] = VaultSyncStatus()
        }

        guard !managers.isEmpty else { return }

        // Periodic pull every 5 minutes
        periodicTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { break }
                await self?.pullAll()
            }
        }
    }

    /// Cancel all sync tasks and clear state.
    @MainActor
    func stop() {
        periodicTask?.cancel()
        periodicTask = nil
        for task in debounceTasks.values { task.cancel() }
        debounceTasks = [:]
        managers = [:]
        vaultSyncStatus = [:]
        isSyncing = false
    }

    // MARK: - Content Change Notification

    /// Notify that content in a vault changed.
    /// Cancels any pending debounce and schedules a full sync after 30 seconds.
    @MainActor
    func notifyContentChanged(vault: VaultEntry) {
        guard managers[vault.name] != nil else { return }
        debounceTasks[vault.name]?.cancel()
        debounceTasks[vault.name] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            await self?.syncVault(vault)
        }
    }

    // MARK: - Sync Operations

    /// Trigger a full sync (pull + push) across all GitHub vaults immediately.
    @MainActor
    func syncNow() {
        Task { @MainActor in await syncAll() }
    }

    /// Pull from all GitHub vaults (e.g., on app foreground).
    @MainActor
    func pullAll() async {
        for (name, manager) in managers {
            await runSync(vaultName: name, manager: manager, operation: .pull)
        }
        lastSyncDate = Date()
    }

    /// Full sync (pull + push) for a single vault.
    @MainActor
    func syncVault(_ entry: VaultEntry) async {
        guard let manager = managers[entry.name] else { return }
        await runSync(vaultName: entry.name, manager: manager, operation: .sync)
    }

    // MARK: - Private Helpers

    private enum SyncOp { case sync, pull, push }

    @MainActor
    private func syncAll() async {
        isSyncing = true
        for (name, manager) in managers {
            await runSync(vaultName: name, manager: manager, operation: .sync)
        }
        isSyncing = false
        lastSyncDate = Date()
    }

    @MainActor
    private func runSync(vaultName: String, manager: GitHubSyncManager, operation: SyncOp) async {
        vaultSyncStatus[vaultName, default: VaultSyncStatus()].isSyncing = true
        do {
            switch operation {
            case .sync: _ = try await manager.sync()
            case .pull: _ = try await manager.pull()
            case .push: _ = try await manager.push()
            }
            vaultSyncStatus[vaultName]?.isSyncing = false
            vaultSyncStatus[vaultName]?.lastSyncDate = Date()
            vaultSyncStatus[vaultName]?.lastError = nil
            lastSyncDate = Date()
        } catch {
            vaultSyncStatus[vaultName]?.isSyncing = false
            vaultSyncStatus[vaultName]?.lastError = error.localizedDescription
            lastSyncError = error.localizedDescription
        }
    }
}
