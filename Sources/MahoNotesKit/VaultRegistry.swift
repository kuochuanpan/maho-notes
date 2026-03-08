import Foundation
import Yams

public enum VaultType: String, Codable, Sendable {
    case icloud, github, local, device
}

public enum VaultAccess: String, Codable, Sendable {
    case readWrite = "read-write"
    case readOnly = "read-only"
}

public struct VaultEntry: Codable, Sendable {
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
        let base = ("~/Library/Mobile Documents/iCloud~dev~pcca~mahonotes/Documents/vaults" as NSString).expandingTildeInPath
        return (base as NSString).appendingPathComponent(entry.name) + "/"
    case .github:
        let base = ("~/.maho/vaults" as NSString).expandingTildeInPath
        return (base as NSString).appendingPathComponent(entry.name) + "/"
    case .device:
        let base = ("~/.maho/vaults" as NSString).expandingTildeInPath
        return (base as NSString).appendingPathComponent(entry.name) + "/"
    case .local:
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
    let iCloudVaultsBase = ("~/Library/Mobile Documents/iCloud~dev~pcca~mahonotes/Documents/vaults" as NSString).expandingTildeInPath
    let localVaultsBase = ("~/.maho/vaults" as NSString).expandingTildeInPath

    var updated = registry

    for (index, entry) in registry.vaults.enumerated() {
        // Only migrate .device vaults (local path-based vaults stay as-is)
        guard entry.type == .device else { continue }

        let sourcePath = resolvedPath(for: entry).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
    let localVaultsBase = ("~/.maho/vaults" as NSString).expandingTildeInPath

    var updated = registry

    for (index, entry) in registry.vaults.enumerated() {
        guard entry.type == .icloud else { continue }

        let sourcePath = resolvedPath(for: entry).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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

/// Reads `sync.cloud` from `globalConfigDir/config.yaml`. Defaults to `.icloud` if absent or unreadable.
func loadCloudSyncMode(globalConfigDir: String = "~/.maho") -> CloudSyncMode {
    let expanded = (globalConfigDir as NSString).expandingTildeInPath
    let configPath = (expanded as NSString).appendingPathComponent("config.yaml")
    guard FileManager.default.fileExists(atPath: configPath),
          let content = try? coordinatedRead(at: configPath),
          let yaml = try? Yams.load(yaml: content) as? [String: Any],
          let sync = yaml["sync"] as? [String: Any],
          let cloud = sync["cloud"] as? String,
          let mode = CloudSyncMode(rawValue: cloud)
    else { return .off }
    return mode
}

/// Writes `sync.cloud` to `globalConfigDir/config.yaml`, preserving other keys.
func setGlobalSyncMode(_ mode: CloudSyncMode, globalConfigDir: String = "~/.maho") throws {
    let expanded = (globalConfigDir as NSString).expandingTildeInPath
    let configPath = (expanded as NSString).appendingPathComponent("config.yaml")

    var yaml: [String: Any] = [:]
    if FileManager.default.fileExists(atPath: configPath),
       let content = try? coordinatedRead(at: configPath),
       let loaded = try? Yams.load(yaml: content) as? [String: Any] {
        yaml = loaded
    }

    var sync = yaml["sync"] as? [String: Any] ?? [:]
    sync["cloud"] = mode.rawValue
    yaml["sync"] = sync

    try FileManager.default.createDirectory(atPath: expanded, withIntermediateDirectories: true)
    try coordinatedWrite(Yams.dump(object: yaml), to: configPath)
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
        .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
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
func checkCloudRegistryExists(globalConfigDir: String = "~/.maho") -> CloudSyncActivationCheck {
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
                    cloudRenamed: cloudRenamed
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

// MARK: - Load / Save

private let iCloudDocumentsPath = "~/Library/Mobile Documents/iCloud~dev~pcca~mahonotes/Documents"
private let registryFileName = "vaults.yaml"
private let cacheFileName = "vaults-cache.yaml"

private func iCloudConfigPath() -> String {
    let docs = (iCloudDocumentsPath as NSString).expandingTildeInPath
    return (docs as NSString).appendingPathComponent("config")
}

/// Loads the vault registry.
/// - Cloud Sync ON (default): tries iCloud config path first, falls back to `globalConfigDir/vaults.yaml`
/// - Cloud Sync OFF: only reads from `globalConfigDir/vaults.yaml`
/// - Parameter globalConfigDir: defaults to `~/.maho`
func loadRegistry(globalConfigDir: String = "~/.maho") throws -> VaultRegistry? {
    let fm = FileManager.default
    let expandedGlobal = (globalConfigDir as NSString).expandingTildeInPath
    let globalPath = (expandedGlobal as NSString).appendingPathComponent(registryFileName)

    let cloudSync = loadCloudSyncMode(globalConfigDir: globalConfigDir)

    if cloudSync == .icloud {
        let iCloudPath = (iCloudConfigPath() as NSString).appendingPathComponent(registryFileName)
        if fm.fileExists(atPath: iCloudPath) {
            let content = try coordinatedRead(at: iCloudPath)
            return try YAMLDecoder().decode(VaultRegistry.self, from: content)
        }
    }

    guard fm.fileExists(atPath: globalPath) else { return nil }
    let content = try coordinatedRead(at: globalPath)
    return try YAMLDecoder().decode(VaultRegistry.self, from: content)
}

/// Saves the vault registry.
/// - Cloud Sync ON (default): writes to iCloud config path if available, else `globalConfigDir/vaults.yaml`;
///   always writes cache to `globalConfigDir/vaults-cache.yaml`
/// - Cloud Sync OFF: writes only to `globalConfigDir/vaults.yaml`; no cache file written
/// - Parameter globalConfigDir: defaults to `~/.maho`
func saveRegistry(_ registry: VaultRegistry, globalConfigDir: String = "~/.maho") throws {
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
        try coordinatedWrite(yaml, to: primaryPath)

        // Write cache when Cloud Sync is ON
        try fm.createDirectory(atPath: expandedGlobal, withIntermediateDirectories: true)
        let cachePath = (expandedGlobal as NSString).appendingPathComponent(cacheFileName)
        try coordinatedWrite(yaml, to: cachePath)
    } else {
        // Cloud Sync OFF: only write to globalConfigDir, no cache
        try fm.createDirectory(atPath: expandedGlobal, withIntermediateDirectories: true)
        let globalPath = (expandedGlobal as NSString).appendingPathComponent(registryFileName)
        try coordinatedWrite(yaml, to: globalPath)
    }
}
