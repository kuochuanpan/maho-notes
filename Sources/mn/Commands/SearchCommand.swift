import ArgumentParser
import Foundation
import MahoNotesKit

struct SearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search notes by text (FTS5 with CJK support)"
    )

    @OptionGroup var vaultOption: VaultOption
    @OptionGroup var outputOption: OutputOption

    @Argument(help: "Search query")
    var query: String

    @Flag(name: .long, help: "Search across all registered vaults (default when --vault is not specified)")
    var all = false

    func run() throws {
        // Default to all vaults unless --vault is explicitly specified
        let searchAll = all || vaultOption.vault == nil
        if searchAll, let entries = vaultOption.allVaultEntries(), !entries.isEmpty {
            try runAllVaults(entries: entries)
            return
        }
        // Single-vault search
        try vaultOption.validateVaultExists()
        let vault = vaultOption.makeVault()
        do {
            let results = try ftsSearch(vault: vault)
            outputResults(results, vaultName: nil, fts: true)
        } catch {
            FileHandle.standardError.write(
                "⚠️  FTS5 search failed (\(error.localizedDescription)), falling back to substring search.\n"
                    .data(using: .utf8)!
            )
            FileHandle.standardError.write(
                "   Run `mn index --full` to rebuild the search index.\n"
                    .data(using: .utf8)!
            )
            let results = try vault.searchNotes(query: query)
            outputSubstringResults(results, vaultName: nil)
        }
    }

    // MARK: - Cross-vault

    private func runAllVaults(entries: [VaultEntry]) throws {
        if outputOption.json {
            var jsonArray: [[String: Any]] = []
            for entry in entries {
                let vault = Vault(path: MahoNotesKit.resolvedPath(for: entry))
                if let results = try? ftsSearch(vault: vault) {
                    for r in results {
                        jsonArray.append([
                            "vault": entry.name,
                            "path": r.path,
                            "title": r.title,
                            "tags": r.tags,
                            "snippet": r.snippet,
                            "rank": r.rank,
                        ])
                    }
                } else if let notes = try? vault.searchNotes(query: query) {
                    for n in notes {
                        jsonArray.append([
                            "vault": entry.name,
                            "path": n.relativePath,
                            "title": n.title,
                            "tags": n.tags,
                            "snippet": "",
                        ])
                    }
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: jsonArray, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return
        }

        var totalCount = 0
        var output: [(vaultName: String, results: [SearchResult])] = []
        var substringOutput: [(vaultName: String, results: [Note])] = []
        var usedFts = true

        for entry in entries {
            let path = MahoNotesKit.resolvedPath(for: entry)
            let vault = Vault(path: path)
            if let results = try? ftsSearch(vault: vault) {
                if !results.isEmpty {
                    output.append((entry.name, results))
                    totalCount += results.count
                }
            } else {
                usedFts = false
                if let results = try? vault.searchNotes(query: query), !results.isEmpty {
                    substringOutput.append((entry.name, results))
                    totalCount += results.count
                }
            }
        }

        if totalCount == 0 {
            print("No results for: \(query)")
            return
        }

        let label = usedFts ? "" : " (substring)"
        print("Found \(totalCount) result(s) for \"\(query)\"\(label):\n")

        for (vaultName, results) in output {
            for result in results {
                let tags = result.tags.isEmpty ? "" : " [\(result.tags.joined(separator: ", "))]"
                print("  [\(vaultName)] \(result.path)")
                print("    \(result.title)\(tags)")
                if !result.snippet.isEmpty {
                    print("    … \(result.snippet)")
                }
                print()
            }
        }
        for (vaultName, notes) in substringOutput {
            for note in notes {
                let tags = note.tags.isEmpty ? "" : " [\(note.tags.joined(separator: ", "))]"
                print("  [\(vaultName)] \(note.relativePath)")
                print("    \(note.title)\(tags)")
                let lines = note.body.components(separatedBy: "\n")
                let queryLower = query.lowercased()
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty && trimmed.lowercased().contains(queryLower) {
                        print("    … \(trimmed.prefix(120))")
                        break
                    }
                }
                print()
            }
        }
    }

    // MARK: - Single-vault helpers

    private func ftsSearch(vault: Vault) throws -> [SearchResult] {
        if !SearchIndex.indexExists(vaultPath: vault.path) {
            FileHandle.standardError.write(
                "Building search index...\n".data(using: .utf8)!
            )
            let index = try SearchIndex(vaultPath: vault.path)
            let notes = try vault.allNotes()
            try index.buildIndex(notes: notes)
            return try index.search(query: query)
        }
        let index = try SearchIndex(vaultPath: vault.path)
        return try index.search(query: query)
    }

    private func outputResults(_ results: [SearchResult], vaultName: String?, fts: Bool) {
        if outputOption.json {
            let jsonArray = results.map { r -> [String: Any] in
                var d: [String: Any] = [
                    "path": r.path,
                    "title": r.title,
                    "tags": r.tags,
                    "snippet": r.snippet,
                    "rank": r.rank,
                ]
                if let v = vaultName { d["vault"] = v }
                return d
            }
            if let data = try? JSONSerialization.data(withJSONObject: jsonArray, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return
        }

        if results.isEmpty {
            print("No results for: \(query)")
            return
        }

        print("Found \(results.count) result(s) for \"\(query)\":\n")
        for result in results {
            let tags = result.tags.isEmpty ? "" : " [\(result.tags.joined(separator: ", "))]"
            let prefix = vaultName.map { "[\($0)] " } ?? ""
            print("  \(prefix)\(result.path)")
            print("    \(result.title)\(tags)")
            if !result.snippet.isEmpty {
                print("    … \(result.snippet)")
            }
            print()
        }
    }

    private func outputSubstringResults(_ results: [Note], vaultName: String?) {
        if outputOption.json {
            try? printJSON(results)
            return
        }

        if results.isEmpty {
            print("No results for: \(query)")
            return
        }

        print("Found \(results.count) result(s) for \"\(query)\" (substring):\n")
        for note in results {
            let tags = note.tags.isEmpty ? "" : " [\(note.tags.joined(separator: ", "))]"
            let prefix = vaultName.map { "[\($0)] " } ?? ""
            print("  \(prefix)\(note.relativePath)")
            print("    \(note.title)\(tags)")

            let lines = note.body.components(separatedBy: "\n")
            let queryLower = query.lowercased()
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && trimmed.lowercased().contains(queryLower) {
                    let snippet = trimmed.prefix(120)
                    print("    … \(snippet)")
                    break
                }
            }
            print()
        }
    }
}
