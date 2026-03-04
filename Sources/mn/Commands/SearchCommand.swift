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

    func run() throws {
        try vaultOption.validateVaultExists()
        let vault = vaultOption.makeVault()

        // Try FTS5 search first
        do {
            let results = try ftsSearch(vault: vault)
            outputResults(results, fts: true)
        } catch {
            // Fallback to substring search
            FileHandle.standardError.write(
                "⚠️  FTS5 search failed (\(error.localizedDescription)), falling back to substring search.\n"
                    .data(using: .utf8)!
            )
            FileHandle.standardError.write(
                "   Run `mn index --full` to rebuild the search index.\n"
                    .data(using: .utf8)!
            )
            let results = try vault.searchNotes(query: query)
            outputSubstringResults(results)
        }
    }

    private func ftsSearch(vault: Vault) throws -> [SearchResult] {
        // Auto-build index if it doesn't exist
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

    private func outputResults(_ results: [SearchResult], fts: Bool) {
        if outputOption.json {
            let jsonArray = results.map { r -> [String: Any] in
                [
                    "path": r.path,
                    "title": r.title,
                    "tags": r.tags,
                    "snippet": r.snippet,
                    "rank": r.rank,
                ]
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
            print("  \(result.path)")
            print("    \(result.title)\(tags)")
            if !result.snippet.isEmpty {
                print("    … \(result.snippet)")
            }
            print()
        }
    }

    private func outputSubstringResults(_ results: [Note]) {
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
            print("  \(note.relativePath)")
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
