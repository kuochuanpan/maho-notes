import ArgumentParser
import MahoNotesKit

struct IndexCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Build or rebuild the full-text search index"
    )

    @OptionGroup var vaultOption: VaultOption
    @OptionGroup var outputOption: OutputOption

    @Flag(name: .long, help: "Full rebuild (drop and recreate)")
    var full = false

    @Flag(name: .long, help: "Index all registered vaults")
    var all = false

    func run() throws {
        if all {
            try runAllVaults()
            return
        }
        try vaultOption.validateVaultExists()
        let vault = vaultOption.makeVault()
        let notes = try vault.allNotes()

        if !outputOption.json {
            if full {
                print("Rebuilding search index from scratch...")
            } else {
                print("Updating search index...")
            }
        }

        let index = try SearchIndex(vaultPath: vault.path)
        let stats = try index.buildIndex(notes: notes, fullRebuild: full)

        if outputOption.json {
            try printJSON(stats)
        } else {
            print("Indexed \(stats.total) notes (\(stats.added) new, \(stats.updated) updated, \(stats.deleted) deleted)")
        }
    }

    // MARK: - Cross-vault

    private func runAllVaults() throws {
        guard let entries = vaultOption.allVaultEntries(), !entries.isEmpty else {
            print("No vaults registered. Use `mn vault add` to add one.")
            return
        }

        struct VaultStats: Encodable {
            let vault: String
            let total: Int
            let added: Int
            let updated: Int
            let deleted: Int
        }
        var allStats: [VaultStats] = []

        for entry in entries {
            let path = MahoNotesKit.resolvedPath(for: entry)
            let vault = Vault(path: path)

            if !outputOption.json {
                let action = full ? "Rebuilding" : "Updating"
                print("\(action) index for vault '\(entry.name)'...")
            }

            do {
                let notes = try vault.allNotes()
                let index = try SearchIndex(vaultPath: vault.path)
                let stats = try index.buildIndex(notes: notes, fullRebuild: full)

                if outputOption.json {
                    allStats.append(VaultStats(
                        vault: entry.name,
                        total: stats.total,
                        added: stats.added,
                        updated: stats.updated,
                        deleted: stats.deleted
                    ))
                } else {
                    print("  [\(entry.name)] \(stats.total) notes (\(stats.added) new, \(stats.updated) updated, \(stats.deleted) deleted)")
                }
            } catch {
                if outputOption.json {
                    allStats.append(VaultStats(vault: entry.name, total: 0, added: 0, updated: 0, deleted: 0))
                } else {
                    print("  [\(entry.name)] Failed: \(error.localizedDescription)")
                }
            }
        }

        if outputOption.json {
            try printJSON(allStats)
        }
    }
}
