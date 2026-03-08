import Foundation
import Observation
import MahoNotesKit

// MARK: - DeviceInfo

enum DeviceInfo {
    static var name: String {
        #if os(macOS)
        Host.current().localizedName ?? "mac"
        #else
        UIDevice.current.name
        #endif
    }

    /// Sanitized for use in filenames (spaces/slashes → hyphens, colons/quotes stripped).
    static var filenameSafe: String {
        name
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
    }
}

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
    /// Conflict files by vault name → list of relative conflict paths (device-name format).
    var githubConflictFiles: [String: [String]] = [:]

    // MARK: - Private State

    private var managers: [String: GitHubSyncManager] = [:]
    private var vaultPaths: [String: String] = [:]
    private var periodicTask: Task<Void, Never>?
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    /// Per-vault lock to prevent concurrent sync operations (avoids 409 race).
    private var syncInProgress: Set<String> = []

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
            let vaultPath = VaultStore.shared.resolvedPath(for: entry)
            guard let manager = GitHubSyncManager.make(
                ownerRepo: ownerRepo,
                branch: "main",
                vaultPath: vaultPath,
                token: token
            ) else { continue }
            managers[entry.name] = manager
            vaultPaths[entry.name] = vaultPath
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
        vaultPaths = [:]
        vaultSyncStatus = [:]
        githubConflictFiles = [:]
        syncInProgress = []
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
    /// Cancels any pending debounce tasks to prevent concurrent sync races.
    @MainActor
    func syncNow() {
        // Cancel debounce tasks to avoid racing with manual sync
        for task in debounceTasks.values { task.cancel() }
        debounceTasks = [:]
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
        // Per-vault lock: skip if another sync is already in-flight for this vault.
        guard !syncInProgress.contains(vaultName) else { return }
        syncInProgress.insert(vaultName)
        defer { syncInProgress.remove(vaultName) }

        vaultSyncStatus[vaultName, default: VaultSyncStatus()].isSyncing = true
        do {
            let result: SyncResult
            switch operation {
            case .sync: result = try await manager.sync()
            case .pull: result = try await manager.pull()
            case .push: result = try await manager.push()
            }
            vaultSyncStatus[vaultName]?.isSyncing = false
            vaultSyncStatus[vaultName]?.lastSyncDate = Date()
            vaultSyncStatus[vaultName]?.lastError = nil
            lastSyncDate = Date()
            processConflicts(vaultName: vaultName, newConflicts: result.conflictFiles)
        } catch {
            vaultSyncStatus[vaultName]?.isSyncing = false
            vaultSyncStatus[vaultName]?.lastError = String(describing: error)
            lastSyncError = String(describing: error)
        }
    }

    /// Rename new timestamp-based conflict files to device-name format, merge with existing,
    /// and prune any that have since been removed from disk.
    @MainActor
    private func processConflicts(vaultName: String, newConflicts: [String]) {
        guard let vaultPath = vaultPaths[vaultName] else { return }
        let deviceName = DeviceInfo.filenameSafe
        let fm = FileManager.default

        // Rename each new conflict file from timestamp format to device-name format
        var renamed: [String] = []
        for conflictPath in newConflicts {
            if let newPath = renameConflictFile(at: conflictPath, in: vaultPath, deviceName: deviceName) {
                renamed.append(newPath)
            } else {
                renamed.append(conflictPath)
            }
        }

        // Prune stale entries, then merge
        let existing = githubConflictFiles[vaultName] ?? []
        let stillExisting = existing.filter { path in
            fm.fileExists(atPath: (vaultPath as NSString).appendingPathComponent(path))
        }
        var combined = stillExisting
        for p in renamed where !combined.contains(p) {
            combined.append(p)
        }
        githubConflictFiles[vaultName] = combined
    }

    /// Rename a `*.conflict-TIMESTAMP-local.*` file to `*.conflict-{deviceName}.*`.
    /// Returns the new relative path on success, nil on failure.
    @MainActor
    private func renameConflictFile(at relativePath: String, in vaultPath: String, deviceName: String) -> String? {
        let url = URL(fileURLWithPath: relativePath)
        let dir = url.deletingLastPathComponent().relativePath
        let ext = url.pathExtension
        let nameNoExt = url.deletingPathExtension().lastPathComponent

        // nameNoExt looks like: "hello.conflict-2026-03-07T15-30-00Z-local"
        guard nameNoExt.hasSuffix("-local"),
              let conflictRange = nameNoExt.range(of: ".conflict-") else { return nil }

        let baseName = String(nameNoExt[nameNoExt.startIndex..<conflictRange.lowerBound])
        let newName = ext.isEmpty
            ? "\(baseName).conflict-\(deviceName)"
            : "\(baseName).conflict-\(deviceName).\(ext)"
        let newRelativePath = (dir == "." || dir.isEmpty) ? newName : "\(dir)/\(newName)"

        let fullOld = (vaultPath as NSString).appendingPathComponent(relativePath)
        let fullNew = (vaultPath as NSString).appendingPathComponent(newRelativePath)

        // If the device-named file already exists (idempotent rename), just return new path
        if FileManager.default.fileExists(atPath: fullNew) { return newRelativePath }

        do {
            try FileManager.default.moveItem(atPath: fullOld, toPath: fullNew)
            return newRelativePath
        } catch {
            return nil
        }
    }
}
