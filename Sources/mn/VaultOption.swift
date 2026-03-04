import ArgumentParser
import Foundation
import MahoNotesKit

/// Shared --vault option used across all commands
struct VaultOption: ParsableArguments {
    @Option(name: .long, help: "Path to the vault directory")
    var vault: String?

    /// Resolve the vault path: --vault flag > MN_VAULT env > iCloud container > ~/maho-vault
    var resolvedPath: String {
        if let vault { return vault }
        if let env = ProcessInfo.processInfo.environment["MN_VAULT"] { return env }
        let icloudPath = ("~/Library/Mobile Documents/iCloud~com.pcca.mahonotes/Documents" as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: icloudPath) { return icloudPath }
        return "~/maho-vault"
    }

    func makeVault() -> Vault {
        Vault(path: resolvedPath)
    }

    /// Validate that the vault exists. Call this from commands that need an existing vault.
    /// Returns a user-friendly error message if the vault is not found.
    func validateVaultExists() throws {
        let expanded = (resolvedPath as NSString).expandingTildeInPath
        let fm = FileManager.default
        guard fm.fileExists(atPath: expanded) else {
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
}
