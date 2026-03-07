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

    @Flag(name: .long, help: "Sync all registered vaults that have GitHub configured")
    var all: Bool = false

    func run() throws {
        if all {
            try runAllVaults()
            return
        }
        try vaultOption.validateVaultExists()
        let vaultPath = (vaultOption.resolvedPath as NSString).expandingTildeInPath

        if !outputOption.json {
            print("Syncing vault at \(vaultPath)...")
        }

        let gitSync = GitSync(vaultPath: vaultPath)
        let result: SyncResult
        do {
            result = try gitSync.sync()
        } catch {
            if outputOption.json {
                let output = ["error": "\(error)"]
                if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
                   let str = String(data: data, encoding: .utf8) {
                    print(str)
                }
            } else {
                print("Sync failed: \(error)")
            }
            throw ExitCode.failure
        }

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

    // MARK: - Cross-vault

    private func runAllVaults() throws {
        guard let entries = vaultOption.allVaultEntries(), !entries.isEmpty else {
            print("No vaults registered. Use `mn vault add` to add one.")
            return
        }

        // Only sync vaults that have GitHub configured
        let syncable = entries.filter { $0.type == .github || $0.github != nil }
        if syncable.isEmpty {
            if !outputOption.json {
                print("No GitHub-backed vaults to sync.")
            } else {
                print("[]")
            }
            return
        }

        var results: [[String: Any]] = []

        let store = VaultStore()
        for entry in syncable {
            let path = store.resolvedPath(for: entry)
            if !outputOption.json {
                print("Syncing vault '\(entry.name)'...")
            }

            do {
                let gitSync = GitSync(vaultPath: path)
                let result = try gitSync.sync()

                if !outputOption.json {
                    print("  [\(entry.name)] \(result.message)")
                } else {
                    results.append(["vault": entry.name, "status": "ok", "message": result.message])
                }

                if reindex {
                    if !outputOption.json { print("  [\(entry.name)] Rebuilding index...") }
                    let vault = Vault(path: path)
                    let notes = try vault.allNotes()
                    let index = try SearchIndex(vaultPath: path)
                    let stats = try index.buildIndex(notes: notes, fullRebuild: true)
                    if !outputOption.json {
                        print("  [\(entry.name)] Index rebuilt: \(stats.total) notes")
                    }
                }
            } catch {
                if !outputOption.json {
                    print("  [\(entry.name)] Failed: \(error.localizedDescription)")
                } else {
                    results.append(["vault": entry.name, "status": "error", "message": error.localizedDescription])
                }
            }
        }

        if outputOption.json,
           let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}
