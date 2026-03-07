import ArgumentParser
import Foundation
import MahoNotesKit

/// Shared --vault option used across all commands
struct VaultOption: ParsableArguments {
    @Option(name: .long, help: "Vault name (from registry) or path to the vault directory")
    var vault: String?

    /// Override for tests — set to a temp dir to avoid touching ~/.maho
    nonisolated(unsafe) static var globalConfigDir: String = "~/.maho"

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
        let icloudPath = ("~/Library/Mobile Documents/iCloud~dev~pcca~mahonotes/Documents" as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: icloudPath) { return icloudPath }
        // Keep ~/maho-vault for backward compat; default to ~/.maho/vaults/ for new installs
        let legacyPath = ("~/maho-vault" as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: legacyPath) { return legacyPath }
        return ("~/.maho/vaults" as NSString).expandingTildeInPath
    }

    private func findEntry(_ identifier: String) -> VaultEntry? {
        (try? VaultStore(globalConfigDir: Self.globalConfigDir).loadRegistrySync())?.findVault(named: identifier)
    }

    func makeVault() -> Vault {
        Vault(path: resolvedPath)
    }

    /// Validate that the vault exists. Call this from commands that need an existing vault.
    func validateVaultExists() throws {
        let expanded = (resolvedPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw ValidationError("""
                Vault not found at: \(expanded)

                To fix this, either:
                  1. Set the MN_VAULT environment variable:
                     export MN_VAULT=~/path/to/your/vault
                  2. Use the --vault flag:
                     mn list --vault ~/path/to/your/vault
                  3. Create a new vault:
                     mn init --vault ~/path/to/your/vault
                """)
        }
    }

    /// Validate that the vault is writable. Call from commands that modify notes.
    func validateWritable() throws {
        if let entry = resolveVaultEntry(), entry.access == .readOnly {
            throw ValidationError("Vault '\(entry.name)' is read-only")
        }
    }
}
