import Foundation
import Yams
#if canImport(UIKit)
import UIKit
#endif

public enum VaultType: String, Codable, Sendable {
    case icloud, github, local, device
}

public enum VaultAccess: String, Codable, Sendable {
    case readWrite = "read-write"
    case readOnly = "read-only"
}

public struct VaultEntry: Codable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let type: VaultType
    public var github: String?
    public var path: String?
    public var access: VaultAccess
    public var displayName: String?
    public var color: String?

    public init(name: String, type: VaultType, github: String? = nil, path: String? = nil, access: VaultAccess, displayName: String? = nil, color: String? = nil) {
        self.name = name
        self.type = type
        self.github = github
        self.path = path
        self.access = access
        self.displayName = displayName
        self.color = color
    }
}

public struct VaultRegistry: Codable, Sendable {
    public var primary: String
    public var vaults: [VaultEntry]

    public init(primary: String, vaults: [VaultEntry]) {
        self.primary = primary
        self.vaults = vaults
    }

    public func findVault(named name: String) -> VaultEntry? {
        vaults.first { $0.name == name }
    }

    public func primaryVault() -> VaultEntry? {
        findVault(named: primary)
    }

    public mutating func addVault(_ entry: VaultEntry) throws {
        guard findVault(named: entry.name) == nil else {
            throw VaultRegistryError.duplicateName(entry.name)
        }
        vaults.append(entry)
    }

    public mutating func removeVault(named name: String) throws {
        let before = vaults.count
        vaults.removeAll { $0.name == name }
        guard vaults.count < before else {
            throw VaultRegistryError.notFound(name)
        }
    }

    public mutating func setPrimary(_ name: String) throws {
        guard findVault(named: name) != nil else {
            throw VaultRegistryError.notFound(name)
        }
        primary = name
    }
}

public enum VaultRegistryError: Error, CustomStringConvertible {
    case duplicateName(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .duplicateName(let name): return "Vault '\(name)' already exists"
        case .notFound(let name): return "Vault '\(name)' not found"
        }
    }
}

// MARK: - Path resolution

func resolvedPath(for entry: VaultEntry) -> String {
    switch entry.type {
    case .icloud:
        let base = (iCloudDocumentsBasePath() as NSString).appendingPathComponent("vaults")
        return (base as NSString).appendingPathComponent(entry.name) + "/"
    case .github, .device:
        let base = mahoConfigBase() + "/vaults"
        return (base as NSString).appendingPathComponent(entry.name) + "/"
    case .local:
        #if os(macOS)
        // Try loading a security-scoped bookmark first (for sandboxed app)
        if let bookmarkURL = loadBookmarkURL(for: entry.name) {
            return bookmarkURL.path
        }
        #endif
        return (entry.path! as NSString).expandingTildeInPath
    }
}

// MARK: - Vault Migration (device ↔ iCloud)

/// Migrates vault data between local storage and iCloud.
/// - Copies vault directory contents from source to destination
/// - Updates vault type in registry
/// - Returns the updated registry
func migrateVaultsToCloud(registry: VaultRegistry) throws -> VaultRegistry {
    let fm = FileManager.default
    let iCloudVaultsBase = (iCloudDocumentsBasePath() as NSString).appendingPathComponent("vaults")
    let localVaultsBase = (mahoConfigBase() as NSString).appendingPathComponent("vaults")

    var updated = registry

    for (index, entry) in registry.vaults.enumerated() {
        // Only migrate .device vaults (local path-based vaults stay as-is)
        guard entry.type == .device else { continue }

        // Only trim trailing slash — leading "/" is part of the absolute path
        var sourcePath = resolvedPath(for: entry)
        while sourcePath.hasSuffix("/") { sourcePath.removeLast() }
        let destPath = (iCloudVaultsBase as NSString).appendingPathComponent(entry.name)

        // Skip if source doesn't exist
        guard fm.fileExists(atPath: sourcePath) else { continue }

        // Create iCloud vaults directory if needed
        try fm.createDirectory(atPath: iCloudVaultsBase, withIntermediateDirectories: true)

        if fm.fileExists(atPath: destPath) {
            // Destination already exists — skip (merge handled separately)
            continue
        }

        // Copy vault contents to iCloud
        try fm.copyItem(atPath: sourcePath, toPath: destPath)

        // Update vault entry type to .icloud (path is derived from name for icloud type)
        updated.vaults[index] = VaultEntry(
            name: entry.name,
            type: .icloud,
            github: entry.github,
            path: nil,
            access: entry.access,
            displayName: entry.displayName,
            color: entry.color
        )
    }

    return updated
}

/// Migrates vault data from iCloud back to local storage.
func migrateVaultsFromCloud(registry: VaultRegistry) throws -> VaultRegistry {
    let fm = FileManager.default
    let localVaultsBase = (mahoConfigBase() as NSString).appendingPathComponent("vaults")

    var updated = registry

    for (index, entry) in registry.vaults.enumerated() {
        guard entry.type == .icloud else { continue }

        // Only trim trailing slash — leading "/" is part of the absolute path
        var sourcePath = resolvedPath(for: entry)
        while sourcePath.hasSuffix("/") { sourcePath.removeLast() }
        let destPath = (localVaultsBase as NSString).appendingPathComponent(entry.name)

        guard fm.fileExists(atPath: sourcePath) else { continue }

        try fm.createDirectory(atPath: localVaultsBase, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: destPath) {
            try fm.copyItem(atPath: sourcePath, toPath: destPath)
        }

        updated.vaults[index] = VaultEntry(
            name: entry.name,
            type: .device,
            github: entry.github,
            path: nil,
            access: entry.access,
            displayName: entry.displayName,
            color: entry.color
        )
    }

    return updated
}

// MARK: - Cloud Sync Mode

public enum CloudSyncMode: String, Codable, Sendable {
    case icloud
    case off
}

/// Reads `sync.cloud` from `globalConfigDir/config.yaml`. Defaults to `.off` if absent or unreadable.
func loadCloudSyncMode(globalConfigDir: String = mahoConfigBase()) -> CloudSyncMode {
    let expanded = (globalConfigDir as NSString).expandingTildeInPath
    let configPath = (expanded as NSString).appendingPathComponent("config.yaml")
    guard FileManager.default.fileExists(atPath: configPath),
          let content = try? String(contentsOfFile: configPath, encoding: .utf8),
          let yaml = try? Yams.load(yaml: content) as? [String: Any],
          let sync = yaml["sync"] as? [String: Any],
          let cloud = sync["cloud"] as? String,
          let mode = CloudSyncMode(rawValue: cloud)
    else { return .off }
    return mode
}

/// Writes `sync.cloud` to `globalConfigDir/config.yaml`, preserving other keys.
func setGlobalSyncMode(_ mode: CloudSyncMode, globalConfigDir: String = mahoConfigBase()) throws {
    let expanded = (globalConfigDir as NSString).expandingTildeInPath
    let configPath = (expanded as NSString).appendingPathComponent("config.yaml")

    var yaml: [String: Any] = [:]
    if FileManager.default.fileExists(atPath: configPath),
       let content = try? String(contentsOfFile: configPath, encoding: .utf8),
       let loaded = try? Yams.load(yaml: content) as? [String: Any] {
        yaml = loaded
    }

    var sync = yaml["sync"] as? [String: Any] ?? [:]
    sync["cloud"] = mode.rawValue
    yaml["sync"] = sync

    try FileManager.default.createDirectory(atPath: expanded, withIntermediateDirectories: true)
    let yamlStr = try Yams.dump(object: yaml)
    try yamlStr.write(toFile: configPath, atomically: true, encoding: .utf8)
}

// MARK: - Device Name

/// Returns a short, filesystem-safe device name for conflict resolution.
public func currentDeviceName() -> String {
    #if os(macOS)
    let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    #else
    let name = UIDevice.current.name
    #endif
    // Make filesystem-safe: lowercase, replace spaces/special chars with hyphens
    let safe = name
        .lowercased()
        .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: String.CompareOptions.regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return safe.isEmpty ? "device" : safe
}

// MARK: - Registry Merge

/// Result of checking whether iCloud already has a registry when enabling cloud sync.
public enum CloudSyncActivationCheck: Sendable {
    /// No iCloud registry exists — safe to upload local registry directly.
    case noCloudRegistry
    /// iCloud registry exists with these vaults. Merge needed.
    case cloudRegistryExists(cloud: VaultRegistry)
}

/// Checks whether iCloud already has a vault registry.
func checkCloudRegistryExists(globalConfigDir: String = mahoConfigBase()) -> CloudSyncActivationCheck {
    let fm = FileManager.default
    let iCloudConfig = iCloudConfigPath()
    let iCloudRegistryPath = (iCloudConfig as NSString).appendingPathComponent(registryFileName)

    if fm.fileExists(atPath: iCloudRegistryPath),
       let content = try? String(contentsOfFile: iCloudRegistryPath, encoding: .utf8),
       let registry = try? YAMLDecoder().decode(VaultRegistry.self, from: content) {
        return .cloudRegistryExists(cloud: registry)
    }
    return .noCloudRegistry
}

/// Describes a name conflict found during merge.
public struct VaultNameConflict: Sendable {
    public let originalName: String
    public let localRenamed: String
    public let cloudRenamed: String
    /// The vault type of the local entry before rename (needed for directory rename).
    public let localType: VaultType
    /// The vault type of the cloud entry before rename (needed for directory rename).
    public let cloudType: VaultType
}

/// Renames vault directories on disk to match conflict-resolved names.
///
/// `mergeRegistries()` only renames registry entries (metadata). This function
/// performs the corresponding filesystem renames so that `resolvedPath(for:)`
/// finds the actual data after the merge.
public func renameConflictedVaultDirectories(_ conflicts: [VaultNameConflict]) throws {
    let fm = FileManager.default

    for conflict in conflicts {
        // Rename local vault directory
        let oldLocalEntry = VaultEntry(name: conflict.originalName, type: conflict.localType,
                                       access: .readWrite)
        let newLocalEntry = VaultEntry(name: conflict.localRenamed, type: conflict.localType,
                                       access: .readWrite)
        let oldLocalPath = resolvedPath(for: oldLocalEntry).trimmingSuffix("/")
        let newLocalPath = resolvedPath(for: newLocalEntry).trimmingSuffix("/")

        if fm.fileExists(atPath: oldLocalPath) && !fm.fileExists(atPath: newLocalPath) {
            try fm.moveItem(atPath: oldLocalPath, toPath: newLocalPath)
        }

        // Rename iCloud vault directory
        let oldCloudEntry = VaultEntry(name: conflict.originalName, type: conflict.cloudType,
                                        access: .readWrite)
        let newCloudEntry = VaultEntry(name: conflict.cloudRenamed, type: conflict.cloudType,
                                        access: .readWrite)
        let oldCloudPath = resolvedPath(for: oldCloudEntry).trimmingSuffix("/")
        let newCloudPath = resolvedPath(for: newCloudEntry).trimmingSuffix("/")

        if fm.fileExists(atPath: oldCloudPath) && !fm.fileExists(atPath: newCloudPath) {
            try fm.moveItem(atPath: oldCloudPath, toPath: newCloudPath)
        }
    }
}

private extension String {
    func trimmingSuffix(_ suffix: Character) -> String {
        var s = self
        while s.hasSuffix(String(suffix)) { s.removeLast() }
        return s
    }
}

/// Merges a local registry with a cloud registry.
/// - Same name + same resolved path → deduplicate (keep one)
/// - Same name + different path → rename both with device suffix
/// - Different names → include both
/// - Returns the merged registry and any conflicts that were resolved.
func mergeRegistries(
    local: VaultRegistry,
    cloud: VaultRegistry,
    localDeviceName: String? = nil
) -> (merged: VaultRegistry, conflicts: [VaultNameConflict]) {
    let deviceName = localDeviceName ?? currentDeviceName()
    var merged: [VaultEntry] = []
    var conflicts: [VaultNameConflict] = []
    var processedCloudNames: Set<String> = []

    for localEntry in local.vaults {
        if let cloudEntry = cloud.vaults.first(where: { $0.name == localEntry.name }) {
            processedCloudNames.insert(cloudEntry.name)

            // Same name — check if same vault (same resolved path)
            let localPath = resolvedPath(for: localEntry)
            let cloudPath = resolvedPath(for: cloudEntry)

            if localPath == cloudPath && localEntry.type == cloudEntry.type {
                // Same vault, deduplicate — keep the cloud version (it's the "existing" one)
                merged.append(cloudEntry)
            } else {
                // Conflict: same name, different vaults → rename both
                let localRenamed = "\(localEntry.name)-\(deviceName)"
                let cloudRenamed = "\(cloudEntry.name)-cloud"

                let renamedLocal = VaultEntry(
                    name: localRenamed,
                    type: localEntry.type,
                    github: localEntry.github,
                    path: localEntry.path,
                    access: localEntry.access,
                    displayName: localEntry.displayName,
                    color: localEntry.color
                )
                let renamedCloud = VaultEntry(
                    name: cloudRenamed,
                    type: cloudEntry.type,
                    github: cloudEntry.github,
                    path: cloudEntry.path,
                    access: cloudEntry.access,
                    displayName: cloudEntry.displayName,
                    color: cloudEntry.color
                )
                merged.append(renamedLocal)
                merged.append(renamedCloud)

                conflicts.append(VaultNameConflict(
                    originalName: localEntry.name,
                    localRenamed: localRenamed,
                    cloudRenamed: cloudRenamed,
                    localType: localEntry.type,
                    cloudType: cloudEntry.type
                ))
            }
        } else {
            // No conflict, include local entry
            merged.append(localEntry)
        }
    }

    // Add remaining cloud entries not yet processed
    for cloudEntry in cloud.vaults where !processedCloudNames.contains(cloudEntry.name) {
        merged.append(cloudEntry)
    }

    // Primary: keep cloud's primary if it exists in merged, else local's, else first
    let primary: String
    if merged.contains(where: { $0.name == cloud.primary }) {
        primary = cloud.primary
    } else if merged.contains(where: { $0.name == local.primary }) {
        primary = local.primary
    } else {
        primary = merged.first?.name ?? "default"
    }

    return (VaultRegistry(primary: primary, vaults: merged), conflicts)
}

// MARK: - Bookmark Resolution (macOS only)

#if os(macOS)
/// Attempts to resolve a saved security-scoped bookmark for a vault.
/// Returns the resolved URL if the bookmark exists and is still valid, nil otherwise.
/// Used by `resolvedPath(for:)` to support sandboxed app access to local vaults.
private func loadBookmarkURL(for vaultName: String) -> URL? {
    let bookmarkDir = (mahoConfigBase() as NSString).appendingPathComponent("bookmarks")
    let bookmarkPath = (bookmarkDir as NSString).appendingPathComponent("\(vaultName).bookmark")
    guard FileManager.default.fileExists(atPath: bookmarkPath) else { return nil }
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: bookmarkPath))
        var isStale = false
        let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
        if isStale { return nil }
        return url
    } catch {
        return nil
    }
}
#endif

// MARK: - Coordinated I/O Helpers

private func coordinatedRead(at path: String) throws -> String {
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

// MARK: - iCloud Container Path

/// The iCloud container identifier for Maho Notes.
private let iCloudContainerID = "iCloud.dev.pcca.mahonotes"

/// Cached iCloud Documents directory path.
/// Uses `FileManager.url(forUbiquityContainerIdentifier:)` which works on both macOS and iOS,
/// returning the correct system-managed path on each platform.
/// Falls back to the hardcoded macOS path for CLI/non-iCloud environments.
private let _iCloudDocumentsBase: String = {
    if let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: iCloudContainerID) {
        return containerURL.appendingPathComponent("Documents").path
    }
    // Fallback: macOS hardcoded path (CLI or when iCloud is unavailable)
    return ("~/Library/Mobile Documents/iCloud~dev~pcca~mahonotes/Documents" as NSString).expandingTildeInPath
}()

/// Returns the iCloud Documents base path, resolved for the current platform.
public func iCloudDocumentsBasePath() -> String {
    _iCloudDocumentsBase
}

// MARK: - Load / Save

private let registryFileName = "vaults.yaml"
private let cacheFileName = "vaults-cache.yaml"

private func iCloudConfigPath() -> String {
    return (iCloudDocumentsBasePath() as NSString).appendingPathComponent("config")
}

/// Loads the vault registry.
/// - Cloud Sync ON (default): tries iCloud config path first, falls back to `globalConfigDir/vaults.yaml`
/// - Cloud Sync OFF: only reads from `globalConfigDir/vaults.yaml`
/// - Parameter globalConfigDir: defaults to `mahoConfigBase()`
func loadRegistry(globalConfigDir: String = mahoConfigBase()) throws -> VaultRegistry? {
    let fm = FileManager.default
    let expandedGlobal = (globalConfigDir as NSString).expandingTildeInPath
    let globalPath = (expandedGlobal as NSString).appendingPathComponent(registryFileName)

    let cloudSync = loadCloudSyncMode(globalConfigDir: globalConfigDir)

    if cloudSync == .icloud {
        let iCloudPath = (iCloudConfigPath() as NSString).appendingPathComponent(registryFileName)
        if fm.fileExists(atPath: iCloudPath) {
            // Use coordinated read for iCloud; fall back to regular read if coordination fails
            let content: String
            do {
                content = try coordinatedRead(at: iCloudPath)
            } catch {
                Log.sync.warning("coordinated read from iCloud failed (\(error.localizedDescription)), falling back to regular read")
                content = try String(contentsOfFile: iCloudPath, encoding: .utf8)
            }
            return try YAMLDecoder().decode(VaultRegistry.self, from: content)
        }
    }

    // Local path — no coordination needed
    guard fm.fileExists(atPath: globalPath) else { return nil }
    let content = try String(contentsOfFile: globalPath, encoding: .utf8)
    return try YAMLDecoder().decode(VaultRegistry.self, from: content)
}

/// Saves the vault registry.
/// - Cloud Sync ON (default): writes to iCloud config path if available, else `globalConfigDir/vaults.yaml`;
///   always writes cache to `globalConfigDir/vaults-cache.yaml`
/// - Cloud Sync OFF: writes only to `globalConfigDir/vaults.yaml`; no cache file written
/// - Parameter globalConfigDir: defaults to `mahoConfigBase()`
func saveRegistry(_ registry: VaultRegistry, globalConfigDir: String = mahoConfigBase()) throws {
    let fm = FileManager.default
    let expandedGlobal = (globalConfigDir as NSString).expandingTildeInPath
    let encoder = YAMLEncoder()
    let yaml = try encoder.encode(registry)

    let cloudSync = loadCloudSyncMode(globalConfigDir: globalConfigDir)

    if cloudSync == .icloud {
        // Write to iCloud config directory (create if needed)
        let iCloudConfig = iCloudConfigPath()
        try fm.createDirectory(atPath: iCloudConfig, withIntermediateDirectories: true)
        let primaryPath = (iCloudConfig as NSString).appendingPathComponent(registryFileName)
        // Use coordinated write for iCloud files; fall back to regular write if
        // NSFileCoordinator fails (e.g. iCloud daemon not ready, permission errors).
        do {
            try coordinatedWrite(yaml, to: primaryPath)
        } catch {
            Log.sync.warning("coordinated write to iCloud failed (\(error.localizedDescription)), falling back to regular write")
            try yaml.write(toFile: primaryPath, atomically: true, encoding: .utf8)
        }

        // Write local cache — no coordination needed (App Group container)
        try fm.createDirectory(atPath: expandedGlobal, withIntermediateDirectories: true)
        let cachePath = (expandedGlobal as NSString).appendingPathComponent(cacheFileName)
        try yaml.write(toFile: cachePath, atomically: true, encoding: .utf8)
    } else {
        // Cloud Sync OFF: only write to globalConfigDir, no cache
        try fm.createDirectory(atPath: expandedGlobal, withIntermediateDirectories: true)
        let globalPath = (expandedGlobal as NSString).appendingPathComponent(registryFileName)
        try yaml.write(toFile: globalPath, atomically: true, encoding: .utf8)
    }
}
