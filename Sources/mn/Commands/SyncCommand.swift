import ArgumentParser
import Foundation
import MahoNotesKit

struct SyncCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Sync vault with remote (git pull + push)"
    )

    @OptionGroup var vaultOption: VaultOption

    func run() throws {
        let vaultPath = vaultOption.resolvedPath
        let expanded = (vaultPath as NSString).expandingTildeInPath
        print("Syncing vault at \(expanded)...")
        try gitSync(vaultPath: vaultPath)
        print("Sync complete.")
    }
}
