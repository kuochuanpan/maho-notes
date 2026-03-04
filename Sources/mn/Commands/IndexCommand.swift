import ArgumentParser
import MahoNotesKit

struct IndexCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Build or rebuild the full-text search index"
    )

    @OptionGroup var vaultOption: VaultOption

    @Flag(name: .long, help: "Full rebuild (drop and recreate)")
    var full = false

    func run() throws {
        try vaultOption.validateVaultExists()
        let vault = vaultOption.makeVault()
        let notes = try vault.allNotes()

        if full {
            print("Rebuilding search index from scratch...")
        } else {
            print("Updating search index...")
        }

        let index = try SearchIndex(vaultPath: vault.path)
        let stats = try index.buildIndex(notes: notes, fullRebuild: full)

        print("Indexed \(stats.total) notes (\(stats.added) new, \(stats.updated) updated, \(stats.deleted) deleted)")
    }
}
