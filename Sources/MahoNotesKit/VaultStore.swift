import Foundation
import Yams

/// Single source of truth for all vault-related persistence.
///
/// `VaultStore` wraps the existing free functions (`loadRegistry`, `saveRegistry`,
/// `resolvedPath`, etc.) behind an actor boundary, providing concurrency safety
/// and a unified API surface.
///
/// **Phase 1**: Non-breaking wrapper. All existing free functions remain untouched.
/// The actor delegates to them, adding typed config support and cache/cleanup features.
public actor VaultStore {

    /// Shared instance for the default global config directory.
    public static let shared = VaultStore()

    /// Root directory for global config.
    private let globalConfigDir: String

    /// Create a VaultStore.
    /// - Parameter globalConfigDir: Path to the global config directory. Tilde is expanded automatically.
    ///   Defaults to platform-appropriate `.maho` directory.
    public init(globalConfigDir: String? = nil) {
        if let dir = globalConfigDir {
            self.globalConfigDir = (dir as NSString).expandingTildeInPath
        } else {
            self.globalConfigDir = mahoConfigBase()
        }
    }

    // ══════════════════════════════════════════
    // MARK: - Registry (vaults.yaml)
    // ══════════════════════════════════════════

    /// Load the vault registry.
    ///
    /// Priority: iCloud (if cloud sync ON) → local → cache fallback.
    /// The cache fallback is new — existing `loadRegistry()` does not read it.
    public func loadRegistry() throws -> VaultRegistry? {
        // Delegate to existing free function first
        if let registry = try MahoNotesKit.loadRegistry(globalConfigDir: globalConfigDir) {
            return registry
        }
        // Fallback to cache when primary sources unavailable
        return try loadCachedRegistry()
    }

    /// Save the vault registry (writes to the correct location based on cloud mode).
    public func saveRegistry(_ registry: VaultRegistry) throws {
        try MahoNotesKit.saveRegistry(registry, globalConfigDir: globalConfigDir)
    }

    /// Load cached registry from `~/.maho/vaults-cache.yaml`.
    ///
    /// This is the offline fallback when iCloud sync is ON but the iCloud
    /// container is unavailable (e.g. offline, not signed in).
    public func loadCachedRegistry() throws -> VaultRegistry? {
        let cachePath = (globalConfigDir as NSString).appendingPathComponent("vaults-cache.yaml")
        guard FileManager.default.fileExists(atPath: cachePath) else { return nil }
        let content = try coordinatedRead(at: cachePath)
        return try YAMLDecoder().decode(VaultRegistry.self, from: content)
    }

    /// Register a new vault entry with simplified validation.
    ///
    /// - `.local`: `path` is required and must point to an existing directory.
    /// - `.icloud`, `.github`, `.device`: `path` is ignored (set to nil);
    ///   the canonical path is derived from the vault name.
    public func registerVault(_ entry: VaultEntry) throws {
        var sanitized = entry

        switch entry.type {
        case .local:
            guard let path = entry.path, !path.isEmpty else {
                throw VaultStoreError.localRequiresPath(entry.name)
            }
            let expanded = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw VaultStoreError.pathDoesNotExist(expanded)
            }
            sanitized = VaultEntry(
                name: entry.name,
                type: .local,
                github: entry.github,
                path: expanded,
                access: entry.access,
                displayName: entry.displayName,
                color: entry.color
            )
        case .icloud, .github, .device:
            // Path is derived from name for these types — ignore any provided path
            sanitized = VaultEntry(
                name: entry.name,
                type: entry.type,
                github: entry.github,
                path: nil,
                access: entry.access,
                displayName: entry.displayName,
                color: entry.color
            )
        }

        var registry = (try? self.loadRegistry()) ?? VaultRegistry(primary: "", vaults: [])
        try registry.addVault(sanitized)

        // Set as primary if it's the first vault
        if registry.vaults.count == 1 {
            try registry.setPrimary(sanitized.name)
        }

        try self.saveRegistry(registry)
    }

    /// Update display name and/or color for a vault entry.
    public func updateVaultEntry(named name: String, displayName: String?, color: String?) throws {
        guard var registry = try self.loadRegistry() else {
            throw VaultRegistryError.notFound(name)
        }
        guard let index = registry.vaults.firstIndex(where: { $0.name == name }) else {
            throw VaultRegistryError.notFound(name)
        }
        let old = registry.vaults[index]
        registry.vaults[index] = VaultEntry(
            name: old.name,
            type: old.type,
            github: old.github,
            path: old.path,
            access: old.access,
            displayName: displayName,
            color: color
        )
        try self.saveRegistry(registry)
    }

    /// Unregister a vault by name.
    public func unregisterVault(named name: String) throws {
        guard var registry = try self.loadRegistry() else {
            throw VaultRegistryError.notFound(name)
        }
        try registry.removeVault(named: name)
        try self.saveRegistry(registry)
    }

    /// Synchronous registry load for CLI contexts where async is not available.
    /// Uses the same logic as the async version: primary sources → cache fallback.
    nonisolated public func loadRegistrySync() throws -> VaultRegistry? {
        if let registry = try MahoNotesKit.loadRegistry(globalConfigDir: globalConfigDir) {
            return registry
        }
        // Cache fallback (same as async loadRegistry)
        let cachePath = (globalConfigDir as NSString).appendingPathComponent("vaults-cache.yaml")
        guard FileManager.default.fileExists(atPath: cachePath) else { return nil }
        let content = try Self.coordinatedRead(at: cachePath)
        return try YAMLDecoder().decode(VaultRegistry.self, from: content)
    }

    // ══════════════════════════════════════════
    // MARK: - Path Resolution
    // ══════════════════════════════════════════

    /// Canonical vault path for a registry entry.
    ///
    /// This is `nonisolated` because path resolution is a pure function —
    /// it derives the path from the entry's type and name without accessing
    /// any mutable actor state. Callers don't need `await`.
    nonisolated public func resolvedPath(for entry: VaultEntry) -> String {
        MahoNotesKit.resolvedPath(for: entry)
    }

    // ══════════════════════════════════════════
    // MARK: - Cloud Sync Mode
    // ══════════════════════════════════════════

    /// Read the current cloud sync mode from global config.
    public func cloudSyncMode() -> CloudSyncMode {
        MahoNotesKit.loadCloudSyncMode(globalConfigDir: globalConfigDir)
    }

    /// Update the cloud sync mode in global config.
    public func setCloudSyncMode(_ mode: CloudSyncMode) throws {
        try MahoNotesKit.setGlobalSyncMode(mode, globalConfigDir: globalConfigDir)
    }

    /// Disable cloud sync: migrate vaults from iCloud, update mode, and clean up artifacts.
    ///
    /// This is the recommended way to turn cloud sync OFF. It handles:
    /// 1. Migrating iCloud vaults back to device storage
    /// 2. Saving the updated registry
    /// 3. Setting cloud sync mode to `.off`
    /// 4. Removing iCloud registry and cache files
    public func disableCloudSync() throws {
        if let registry = try self.loadRegistry() {
            let migrated = try migrateFromCloud(registry)
            try self.saveRegistry(migrated)
        }
        try setCloudSyncMode(.off)
        try cleanupCloudArtifacts()
    }

    // ══════════════════════════════════════════
    // MARK: - Cloud Migration
    // ══════════════════════════════════════════

    /// Migrate device vaults to iCloud. Returns the updated registry.
    public func migrateToCloud(_ registry: VaultRegistry) throws -> VaultRegistry {
        try MahoNotesKit.migrateVaultsToCloud(registry: registry)
    }

    /// Migrate iCloud vaults back to device. Returns the updated registry.
    public func migrateFromCloud(_ registry: VaultRegistry) throws -> VaultRegistry {
        try MahoNotesKit.migrateVaultsFromCloud(registry: registry)
    }

    /// Check whether iCloud already has a vault registry.
    public func checkCloudRegistryExists() -> CloudSyncActivationCheck {
        MahoNotesKit.checkCloudRegistryExists(globalConfigDir: globalConfigDir)
    }

    /// Merge a local registry with a cloud registry, resolving name conflicts.
    public func mergeRegistries(
        local: VaultRegistry,
        cloud: VaultRegistry,
        localDeviceName: String? = nil
    ) -> (merged: VaultRegistry, conflicts: [VaultNameConflict]) {
        MahoNotesKit.mergeRegistries(local: local, cloud: cloud, localDeviceName: localDeviceName)
    }

    /// Remove iCloud registry and stale iCloud vault copies.
    ///
    /// Called when turning cloud sync OFF to prevent orphan data
    /// from causing unexpected merges when cloud sync is re-enabled.
    public func cleanupCloudArtifacts() throws {
        let fm = FileManager.default
        let iCloudBase = iCloudDocumentsBasePath()

        // Remove iCloud registry
        let iCloudConfigDir = (iCloudBase as NSString).appendingPathComponent("config")
        let iCloudRegistryPath = (iCloudConfigDir as NSString).appendingPathComponent("vaults.yaml")
        if fm.fileExists(atPath: iCloudRegistryPath) {
            try fm.removeItem(atPath: iCloudRegistryPath)
        }

        // Remove local cache (no longer needed when cloud is OFF)
        let cachePath = (globalConfigDir as NSString).appendingPathComponent("vaults-cache.yaml")
        if fm.fileExists(atPath: cachePath) {
            try fm.removeItem(atPath: cachePath)
        }
    }

    // ══════════════════════════════════════════
    // MARK: - Vault Config (maho.yaml)
    // ══════════════════════════════════════════

    /// Load typed vault configuration from `<vaultPath>/maho.yaml`.
    public func loadVaultConfig(at vaultPath: String) throws -> VaultConfig {
        let path = (vaultPath as NSString).appendingPathComponent("maho.yaml")
        guard FileManager.default.fileExists(atPath: path) else {
            return VaultConfig()
        }
        let content = try coordinatedRead(at: path)
        return try YAMLDecoder().decode(VaultConfig.self, from: content)
    }

    /// Save typed vault configuration to `<vaultPath>/maho.yaml`.
    public func saveVaultConfig(_ config: VaultConfig, at vaultPath: String) throws {
        let path = (vaultPath as NSString).appendingPathComponent("maho.yaml")
        let encoder = YAMLEncoder()
        let yaml = try encoder.encode(config)
        try coordinatedWrite(yaml, to: path)
    }

    // ══════════════════════════════════════════
    // MARK: - Device Config (.maho/config.yaml)
    // ══════════════════════════════════════════

    /// Load typed device configuration from `<vaultPath>/.maho/config.yaml`.
    public func loadDeviceConfig(at vaultPath: String) throws -> DeviceConfig {
        let mahoDir = (vaultPath as NSString).appendingPathComponent(".maho")
        let path = (mahoDir as NSString).appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: path) else {
            return DeviceConfig()
        }
        let content = try coordinatedRead(at: path)
        return try YAMLDecoder().decode(DeviceConfig.self, from: content)
    }

    /// Save typed device configuration to `<vaultPath>/.maho/config.yaml`.
    public func saveDeviceConfig(_ config: DeviceConfig, at vaultPath: String) throws {
        let mahoDir = (vaultPath as NSString).appendingPathComponent(".maho")
        let fm = FileManager.default
        if !fm.fileExists(atPath: mahoDir) {
            try fm.createDirectory(atPath: mahoDir, withIntermediateDirectories: true)
        }
        let path = (mahoDir as NSString).appendingPathComponent("config.yaml")
        let encoder = YAMLEncoder()
        let yaml = try encoder.encode(config)
        try coordinatedWrite(yaml, to: path)
    }

    // ══════════════════════════════════════════
    // MARK: - Global Config (~/.maho/config.yaml)
    // ══════════════════════════════════════════

    /// Load typed global configuration from `~/.maho/config.yaml`.
    public func loadGlobalConfig() throws -> GlobalConfig {
        let path = (globalConfigDir as NSString).appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: path) else {
            return GlobalConfig()
        }
        let content = try coordinatedRead(at: path)
        return try YAMLDecoder().decode(GlobalConfig.self, from: content)
    }

    /// Save typed global configuration to `~/.maho/config.yaml`.
    public func saveGlobalConfig(_ config: GlobalConfig) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: globalConfigDir) {
            try fm.createDirectory(atPath: globalConfigDir, withIntermediateDirectories: true)
        }
        let path = (globalConfigDir as NSString).appendingPathComponent("config.yaml")
        let encoder = YAMLEncoder()
        let yaml = try encoder.encode(config)
        try coordinatedWrite(yaml, to: path)
    }

    /// The file path of the local vault registry.
    nonisolated public var localRegistryPath: String {
        (globalConfigDir as NSString).appendingPathComponent("vaults.yaml")
    }

    // ══════════════════════════════════════════
    // MARK: - Security-Scoped Bookmarks (macOS)
    // ══════════════════════════════════════════

    #if os(macOS)
    /// Creates a security-scoped bookmark for a vault URL and saves it to disk.
    ///
    /// The bookmark allows the sandboxed app to re-access a user-selected directory
    /// across launches without requiring a new file-picker interaction.
    public func saveBookmark(for url: URL, vaultName: String) throws {
        let bookmarkData = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let bookmarkDir = (globalConfigDir as NSString).appendingPathComponent("bookmarks")
        let fm = FileManager.default
        if !fm.fileExists(atPath: bookmarkDir) {
            try fm.createDirectory(atPath: bookmarkDir, withIntermediateDirectories: true)
        }
        let bookmarkPath = (bookmarkDir as NSString).appendingPathComponent("\(vaultName).bookmark")
        try bookmarkData.write(to: URL(fileURLWithPath: bookmarkPath))
    }

    /// Loads and resolves a saved security-scoped bookmark for a vault.
    ///
    /// Returns the resolved URL if the bookmark exists and is valid, nil otherwise.
    public func loadBookmark(for vaultName: String) -> URL? {
        let bookmarkDir = (globalConfigDir as NSString).appendingPathComponent("bookmarks")
        let bookmarkPath = (bookmarkDir as NSString).appendingPathComponent("\(vaultName).bookmark")
        guard FileManager.default.fileExists(atPath: bookmarkPath) else { return nil }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: bookmarkPath))
            var isStale = false
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale {
                // Re-save the bookmark to refresh it
                try? saveBookmark(for: url, vaultName: vaultName)
            }
            return url
        } catch {
            return nil
        }
    }

    /// Loads a bookmark and starts accessing the security-scoped resource.
    ///
    /// The caller must call `stopAccessingVault(url:)` when done.
    public func startAccessingVault(named vaultName: String) -> URL? {
        guard let url = loadBookmark(for: vaultName) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        return url
    }

    /// Stops accessing a security-scoped resource.
    nonisolated public func stopAccessingVault(url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
    #endif

    // MARK: - Coordinated I/O

    /// Read file content using NSFileCoordinator for cross-process safety.
    private func coordinatedRead(at path: String) throws -> String {
        try Self.coordinatedRead(at: path)
    }

    /// Write content using NSFileCoordinator for cross-process safety.
    private func coordinatedWrite(_ content: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        var coordError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordError) { actualURL in
            do {
                try content.write(to: actualURL, atomically: true, encoding: .utf8)
            } catch {
                writeError = error
            }
        }
        if let e = coordError { throw e }
        if let e = writeError { throw e }
    }

    /// Nonisolated coordinated read for use in both actor and nonisolated contexts.
    nonisolated private static func coordinatedRead(at path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        var result: String = ""
        var coordError: NSError?
        var readError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { actualURL in
            do {
                result = try String(contentsOf: actualURL, encoding: .utf8)
            } catch {
                readError = error
            }
        }
        if let e = coordError { throw e }
        if let e = readError { throw e }
        return result
    }
}

// MARK: - Errors

public enum VaultStoreError: Error, CustomStringConvertible {
    case localRequiresPath(String)
    case pathDoesNotExist(String)

    public var description: String {
        switch self {
        case .localRequiresPath(let name):
            return "Vault '\(name)' has type .local but no path was provided"
        case .pathDoesNotExist(let path):
            return "Path does not exist: \(path)"
        }
    }
}
