import ArgumentParser
import Foundation
import MahoNotesKit

struct SyncCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Sync vault with GitHub (git pull + push)"
    )

    @OptionGroup var vaultOption: VaultOption
    @OptionGroup var outputOption: OutputOption

    @Flag(name: .long, help: "Rebuild search index after sync")
    var reindex: Bool = false

    func run() throws {
        try vaultOption.validateVaultExists()
        let vaultPath = (vaultOption.resolvedPath as NSString).expandingTildeInPath

        if !outputOption.json {
            print("Syncing vault at \(vaultPath)...")
        }

        let gitSync = GitSync(vaultPath: vaultPath)
        let result = try gitSync.sync()

        if !outputOption.json {
            print(result.message)
        }

        if reindex {
            if !outputOption.json {
                print("Rebuilding search index...")
            }
            let vault = Vault(path: vaultPath)
            let notes = try vault.allNotes()
            let index = try SearchIndex(vaultPath: vaultPath)
            let stats = try index.buildIndex(notes: notes, fullRebuild: true)
            if !outputOption.json {
                print("Index rebuilt: \(stats.total) notes indexed (\(stats.added) added, \(stats.updated) updated, \(stats.deleted) deleted)")
            }
        }

        if outputOption.json {
            try printJSON(result)
        }
    }
}
