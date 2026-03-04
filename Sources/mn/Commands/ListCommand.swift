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

    @Option(name: .long, help: "List all series across vault")
    var series: String?

    @Flag(name: .long, help: "Show available collections")
    var listCollections = false

    @Flag(name: .long, help: "Show available tags")
    var listTags = false

    @Flag(name: .long, help: "Show all series")
    var listSeries = false

    func run() throws {
        try vaultOption.validateVaultExists()
        let vault = vaultOption.makeVault()
        let collections = try vault.collections()

        // mn list --list-collections → show available collection ids
        if listCollections {
            if outputOption.json {
                try printJSON(collections)
            } else {
                print("Available collections:")
                for coll in collections {
                    print("  \(coll.cliIcon) \(coll.id) — \(coll.name)")
                }
            }
            return
        }

        // mn list --list-tags → show all tags in vault
        if listTags {
            let allNotes = try vault.allNotes()
            let tagCounts = Dictionary(allNotes.flatMap(\.tags).map { ($0, 1) }, uniquingKeysWith: +)
                .sorted { $0.value > $1.value }
            if outputOption.json {
                try printJSON(Dictionary(uniqueKeysWithValues: tagCounts))
            } else {
                print("Available tags:")
                for (tag, count) in tagCounts {
                    print("  \(tag) (\(count))")
                }
            }
            return
        }

        // mn list --list-series → show all series
        if listSeries {
            let allNotes = try vault.allNotes()
            let seriesCounts = Dictionary(allNotes.compactMap(\.series).map { ($0, 1) }, uniquingKeysWith: +)
                .sorted { $0.value > $1.value }
            if outputOption.json {
                try printJSON(Dictionary(uniqueKeysWithValues: seriesCounts))
            } else {
                print("Available series:")
                for (s, count) in seriesCounts {
                    print("  \(s) (\(count))")
                }
            }
            return
        }

        // Validate collection if provided
        if let collection, !collections.contains(where: { $0.id == collection }) {
            let valid = collections.map(\.id).joined(separator: ", ")
            throw ValidationError("Unknown collection '\(collection)'. Available: \(valid)")
        }

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

            print("\(coll.cliIcon) \(coll.name) (\(coll.id))")
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
