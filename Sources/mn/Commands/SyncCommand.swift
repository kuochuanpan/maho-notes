import ArgumentParser
import Foundation
import MahoNotesKit

struct SyncCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Sync vault with GitHub (git pull + push)"
    )

    @OptionGroup var vaultOption: VaultOption

    @Flag(name: .long, help: "Rebuild search index after sync")
    var reindex: Bool = false

    func run() throws {
        try vaultOption.validateVaultExists()
        let vaultPath = (vaultOption.resolvedPath as NSString).expandingTildeInPath
        print("Syncing vault at \(vaultPath)...")

        let gitSync = GitSync(vaultPath: vaultPath)
        let result = try gitSync.sync()
        print(result.message)

        if reindex {
            print("Rebuilding search index...")
            let vault = Vault(path: vaultPath)
            let notes = try vault.allNotes()
            let index = try SearchIndex(vaultPath: vaultPath)
            let stats = try index.buildIndex(notes: notes, fullRebuild: true)
            print("Index rebuilt: \(stats.total) notes indexed (\(stats.added) added, \(stats.updated) updated, \(stats.deleted) deleted)")
        }
    }
}
