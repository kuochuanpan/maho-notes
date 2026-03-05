import Foundation
import Yams

public enum VaultType: String, Codable, Sendable {
    case icloud, github, local
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
        let base = ("~/Library/Mobile Documents/iCloud~com.pcca.mahonotes/Documents/vaults" as NSString).expandingTildeInPath
        return (base as NSString).appendingPathComponent(entry.name) + "/"
    case .github:
        let base = ("~/.maho/vaults" as NSString).expandingTildeInPath
        return (base as NSString).appendingPathComponent(entry.name) + "/"
    case .local:
        return (entry.path! as NSString).expandingTildeInPath
    }
}

// MARK: - Load / Save

private let iCloudDocumentsPath = "~/Library/Mobile Documents/iCloud~com.pcca.mahonotes/Documents"
private let registryFileName = "vaults.yaml"
private let cacheFileName = "vaults-cache.yaml"

private func iCloudConfigPath() -> String {
    let docs = (iCloudDocumentsPath as NSString).expandingTildeInPath
    return (docs as NSString).appendingPathComponent("config")
}

/// Loads the vault registry.
/// Search order: iCloud config path → `globalConfigDir`/vaults.yaml
/// - Parameter globalConfigDir: defaults to `~/.maho`
public func loadRegistry(globalConfigDir: String = "~/.maho") throws -> VaultRegistry? {
    let fm = FileManager.default
    let expandedGlobal = (globalConfigDir as NSString).expandingTildeInPath

    let iCloudPath = (iCloudConfigPath() as NSString).appendingPathComponent(registryFileName)
    let globalPath = (expandedGlobal as NSString).appendingPathComponent(registryFileName)

    let candidates = [iCloudPath, globalPath]
    for path in candidates {
        guard fm.fileExists(atPath: path) else { continue }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let decoder = YAMLDecoder()
        return try decoder.decode(VaultRegistry.self, from: content)
    }
    return nil
}

/// Saves the vault registry.
/// Writes to the iCloud config path if available, otherwise `globalConfigDir`/vaults.yaml.
/// Always writes a cache copy to `globalConfigDir`/vaults-cache.yaml.
/// - Parameter globalConfigDir: defaults to `~/.maho`
public func saveRegistry(_ registry: VaultRegistry, globalConfigDir: String = "~/.maho") throws {
    let fm = FileManager.default
    let expandedGlobal = (globalConfigDir as NSString).expandingTildeInPath
    let encoder = YAMLEncoder()
    let yaml = try encoder.encode(registry)

    // Determine primary save location
    let iCloudConfig = iCloudConfigPath()
    let primaryPath: String
    if fm.fileExists(atPath: iCloudConfig) {
        primaryPath = (iCloudConfig as NSString).appendingPathComponent(registryFileName)
    } else {
        try fm.createDirectory(atPath: expandedGlobal, withIntermediateDirectories: true)
        primaryPath = (expandedGlobal as NSString).appendingPathComponent(registryFileName)
    }
    try yaml.write(toFile: primaryPath, atomically: true, encoding: .utf8)

    // Always write cache
    try fm.createDirectory(atPath: expandedGlobal, withIntermediateDirectories: true)
    let cachePath = (expandedGlobal as NSString).appendingPathComponent(cacheFileName)
    try yaml.write(toFile: cachePath, atomically: true, encoding: .utf8)
}
