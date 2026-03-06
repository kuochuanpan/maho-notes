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

    public init(name: String, type: VaultType, github: String? = nil, path: String? = nil, access: VaultAccess) {
        self.name = name
        self.type = type
        self.github = github
        self.path = path
        self.access = access
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

public func resolvedPath(for entry: VaultEntry) -> String {
    switch entry.type {
    case .icloud:
        let base = ("~/Library/Mobile Documents/iCloud~dev.pcca.mahonotes/Documents/vaults" as NSString).expandingTildeInPath
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

// MARK: - Cloud Sync Mode

public enum CloudSyncMode: String, Codable, Sendable {
    case icloud
    case off
}

/// Reads `sync.cloud` from `globalConfigDir/config.yaml`. Defaults to `.icloud` if absent or unreadable.
public func loadCloudSyncMode(globalConfigDir: String = "~/.maho") -> CloudSyncMode {
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
public func setGlobalSyncMode(_ mode: CloudSyncMode, globalConfigDir: String = "~/.maho") throws {
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
    try Yams.dump(object: yaml).write(toFile: configPath, atomically: true, encoding: .utf8)
}

// MARK: - Load / Save

private let iCloudDocumentsPath = "~/Library/Mobile Documents/iCloud~dev.pcca.mahonotes/Documents"
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
public func loadRegistry(globalConfigDir: String = "~/.maho") throws -> VaultRegistry? {
    let fm = FileManager.default
    let expandedGlobal = (globalConfigDir as NSString).expandingTildeInPath
    let globalPath = (expandedGlobal as NSString).appendingPathComponent(registryFileName)

    let cloudSync = loadCloudSyncMode(globalConfigDir: globalConfigDir)

    if cloudSync == .icloud {
        let iCloudPath = (iCloudConfigPath() as NSString).appendingPathComponent(registryFileName)
        if fm.fileExists(atPath: iCloudPath) {
            let content = try String(contentsOfFile: iCloudPath, encoding: .utf8)
            return try YAMLDecoder().decode(VaultRegistry.self, from: content)
        }
    }

    guard fm.fileExists(atPath: globalPath) else { return nil }
    let content = try String(contentsOfFile: globalPath, encoding: .utf8)
    return try YAMLDecoder().decode(VaultRegistry.self, from: content)
}

/// Saves the vault registry.
/// - Cloud Sync ON (default): writes to iCloud config path if available, else `globalConfigDir/vaults.yaml`;
///   always writes cache to `globalConfigDir/vaults-cache.yaml`
/// - Cloud Sync OFF: writes only to `globalConfigDir/vaults.yaml`; no cache file written
/// - Parameter globalConfigDir: defaults to `~/.maho`
public func saveRegistry(_ registry: VaultRegistry, globalConfigDir: String = "~/.maho") throws {
    let fm = FileManager.default
    let expandedGlobal = (globalConfigDir as NSString).expandingTildeInPath
    let encoder = YAMLEncoder()
    let yaml = try encoder.encode(registry)

    let cloudSync = loadCloudSyncMode(globalConfigDir: globalConfigDir)

    if cloudSync == .icloud {
        // Determine primary save location
        let iCloudConfig = iCloudConfigPath()
        if fm.fileExists(atPath: iCloudConfig) {
            let primaryPath = (iCloudConfig as NSString).appendingPathComponent(registryFileName)
            try yaml.write(toFile: primaryPath, atomically: true, encoding: .utf8)
        } else {
            try fm.createDirectory(atPath: expandedGlobal, withIntermediateDirectories: true)
            let globalPath = (expandedGlobal as NSString).appendingPathComponent(registryFileName)
            try yaml.write(toFile: globalPath, atomically: true, encoding: .utf8)
        }

        // Write cache when Cloud Sync is ON
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
