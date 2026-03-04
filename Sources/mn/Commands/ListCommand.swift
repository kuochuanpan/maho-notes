import ArgumentParser
import MahoNotesKit

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List notes grouped by collection"
    )

    @OptionGroup var vaultOption: VaultOption
    @OptionGroup var outputOption: OutputOption

    @Option(name: .long, help: "Filter by collection id")
    var collection: String?

    @Option(name: .long, help: "Filter by tag")
    var tag: String?

    func run() throws {
        try vaultOption.validateVaultExists()
        let vault = vaultOption.makeVault()
        let collections = try vault.collections()
        let notes = try vault.listNotes(collection: collection, tag: tag)

        if outputOption.json {
            try printJSON(notes)
            return
        }

        if notes.isEmpty {
            print("No notes found.")
            return
        }

        // Group notes by collection
        let grouped = Dictionary(grouping: notes, by: { $0.collection })

        for coll in collections {
            guard let collNotes = grouped[coll.id], !collNotes.isEmpty else { continue }

            print("\(coll.icon) \(coll.name) (\(coll.id))")
            print(String(repeating: "─", count: 40))

            let sorted = collNotes.sorted {
                ($0.order ?? 999) < ($1.order ?? 999)
            }

            for note in sorted {
                let tags = note.tags.isEmpty ? "" : " [\(note.tags.joined(separator: ", "))]"
                let date = String(note.created.prefix(10))
                print("  \(note.relativePath)")
                print("    \(note.title)\(tags)  \(date)")
            }
            print()
        }

        // Notes with unrecognized collections
        let knownIds = Set(collections.map(\.id))
        let uncategorized = grouped.filter { !knownIds.contains($0.key) }
        for (collId, collNotes) in uncategorized {
            print("? \(collId)")
            print(String(repeating: "─", count: 40))
            for note in collNotes {
                let tags = note.tags.isEmpty ? "" : " [\(note.tags.joined(separator: ", "))]"
                print("  \(note.relativePath)")
                print("    \(note.title)\(tags)")
            }
            print()
        }
    }
}
