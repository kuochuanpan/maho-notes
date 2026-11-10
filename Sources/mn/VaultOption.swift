import ArgumentParser
import Foundation
import MahoNotesKit

/// Shared --vault option used across all commands
struct VaultOption: ParsableArguments {
    @Option(name: .long, help: "Vault name (from registry) or path to the vault directory")
    var vault: String?

    /// Override for tests — set to a temp dir to avoid touching the config directory
    nonisolated(unsafe) static var globalConfigDir: String = mahoConfigBase()

    /// Returns the registry entry for the resolved vault, if found in registry.
    func resolveVaultEntry() -> VaultEntry? {
        guard let registry = try? VaultStore(globalConfigDir: Self.globalConfigDir).loadRegistrySync() else {
            return nil
        }
        let identifier = vault ?? ProcessInfo.processInfo.environment["MN_VAULT"]
        if let identifier {
            return registry.findVault(named: identifier)
        }
        return registry.primaryVault()
    }

    /// All vault entries from registry, or nil if no registry exists.
    func allVaultEntries() -> [VaultEntry]? {
        try? VaultStore(globalConfigDir: Self.globalConfigDir).loadRegistrySync()?.vaults
    }

    /// Resolve the vault path:
    ///   1. --vault flag → name in registry, then treat as path
    ///   2. $MN_VAULT env → name in registry, then treat as path
    ///   3. Primary vault from registry
    ///   4. Legacy fallback: iCloud container → ~/maho-vault
    var resolvedPath: String {
        if let vault {
            if let entry = findEntry(vault) {
                return VaultStore.shared.resolvedPath(for: entry)
            }
            return vault
        }
        if let env = ProcessInfo.processInfo.environment["MN_VAULT"] {
            if let entry = findEntry(env) {
                return VaultStore.shared.resolvedPath(for: entry)
            }
            return env
        }
        if let registry = try? VaultStore(globalConfigDir: Self.globalConfigDir).loadRegistrySync(),
           let primary = registry.primaryVault() {
            return VaultStore.shared.resolvedPath(for: primary)
        }
        // Legacy fallback
        let icloudPath = iCloudDocumentsBasePath()
        if FileManager.default.fileExists(atPath: icloudPath) { return icloudPath }
        // Keep ~/maho-vault for backward compat; default to ~/.maho/vaults/ for new installs
        let legacyPath = ("~/maho-vault" as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: legacyPath) { return legacyPath }
        return (mahoConfigBase() as NSString).appendingPathComponent("vaults")
    }

    private func findEntry(_ identifier: String) -> VaultEntry? {
        (try? VaultStore(globalConfigDir: Self.globalConfigDir).loadRegistrySync())?.findVault(named: identifier)
    }

    func makeVault() -> Vault {
        // Absolute, so `absolutePath` in results is usable from any working directory
        // even when the vault was given as `--vault .` or a relative folder.
        let expanded = (resolvedPath as NSString).expandingTildeInPath
        return Vault(path: URL(fileURLWithPath: expanded).standardizedFileURL.path)
    }

    /// Validate that the vault exists. Call this from commands that need an existing vault.
    func validateVaultExists() throws {
        let expanded = (resolvedPath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
            let requested = vault ?? ProcessInfo.processInfo.environment["MN_VAULT"]
            let names = (allVaultEntries() ?? []).map(\.name)
            let registered = names.isEmpty
                ? "No vaults are registered yet — run `mn init`."
                : "Registered vaults: \(names.joined(separator: ", "))."
            throw CLIError(
                code: "vault_not_found",
                message: requested.map { "Vault not found: \($0) (looked in \(expanded))" }
                    ?? "Vault not found at \(expanded)",
                hint: "\(registered) Pass --vault <name or folder path>, or set MN_VAULT."
            )
        }
    }

    /// Validate that the vault is writable. Call from commands that modify notes.
    func validateWritable() throws {
        if let entry = resolveVaultEntry(), entry.access == .readOnly {
            throw CLIError(code: "vault_read_only", message: "Vault '\(entry.name)' is read-only")
        }
    }

    /// The vault for a command that reads notes.
    func existingVault() throws -> Vault {
        try validateVaultExists()
        return makeVault()
    }

    /// The vault for a command that changes notes.
    func writableVault() throws -> Vault {
        try validateVaultExists()
        try validateWritable()
        return makeVault()
    }
}
