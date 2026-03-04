import ArgumentParser
import MahoNotesKit

struct SearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search notes by text"
    )

    @OptionGroup var vaultOption: VaultOption

    @Argument(help: "Search query")
    var query: String

    func run() throws {
        let vault = vaultOption.makeVault()
        let results = try vault.searchNotes(query: query)

        if results.isEmpty {
            print("No results for: \(query)")
            return
        }

        print("Found \(results.count) result(s) for \"\(query)\":\n")
        for note in results {
            let tags = note.tags.isEmpty ? "" : " [\(note.tags.joined(separator: ", "))]"
            print("  \(note.relativePath)")
            print("    \(note.title)\(tags)")

            // Show a snippet of matching content
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
