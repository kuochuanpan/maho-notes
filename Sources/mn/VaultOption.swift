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
}
