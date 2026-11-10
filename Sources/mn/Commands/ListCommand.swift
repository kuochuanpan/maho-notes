import ArgumentParser
import Foundation
import MahoNotesKit

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List notes grouped by collection",
        discussion: """
            JSON output carries each note's metadata without its body (add --body to \
            include it, or read one note with `mn show <path> --json`).

              mn list --sort updated --limit 10 --json     # the ten most recently changed notes
            """
    )

    enum SortKey: String, ExpressibleByArgument, CaseIterable {
        case updated, created, title
    }

    @OptionGroup var vaultOption: VaultOption
    @OptionGroup var outputOption: OutputOption

    @Option(name: .long, help: "Filter by collection path (e.g., japanese or japanese/grammar)")
    var collection: String?

    @Option(name: .long, help: "Filter by tag")
    var tag: String?

    @Option(name: .long, help: "Filter by series")
    var series: String?

    @Option(name: .long, help: "Sort by updated or created (newest first) or title; default is the vault's own order")
    var sort: SortKey?

    @Option(name: .long, help: "Show at most this many notes")
    var limit: Int?

    @Flag(name: .long, help: "Include note bodies in JSON output")
    var body = false

    @Flag(name: .long, help: "Show available collections")
    var listCollections = false

    @Flag(name: .long, help: "Show available tags")
    var listTags = false

    @Flag(name: .long, help: "Show all series")
    var listSeries = false

    @Flag(name: .long, help: "List notes across all registered vaults")
    var all = false

    func validate() throws {
        if let limit, limit < 1 {
            throw ValidationError("--limit must be at least 1.")
        }
    }

    func run() throws {
        if all {
            try runAllVaults()
            return
        }
        let vault = try vaultOption.existingVault()
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

        // A collection filter may name a nested collection; it has to be a folder in the vault.
        var collectionFilter: String?
        if let collection {
            let normalized = try vault.normalizedCollectionPath(collection)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: vault.absolutePath(for: normalized), isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw NoteError.collectionNotFound(normalized, available: collections.map(\.id))
            }
            collectionFilter = normalized
        }

        let notes = select(try vault.listNotes(collection: collectionFilter, tag: tag), vault: vault, collections: collections)

        if outputOption.json {
            try printJSON(notes.map { NoteOutput($0, includeBody: body) })
            return
        }

        if notes.isEmpty {
            print("No notes found.")
            return
        }
        printNotes(notes, collections: collections, vaultName: nil)
    }

    // MARK: - Selection

    /// Apply the series filter, the requested order and the limit.
    private func select(_ notes: [Note], vault: Vault, collections: [Collection]) -> [Note] {
        var result = notes
        if let series {
            result = result.filter { $0.series == series }
        }
        switch sort {
        case .updated:
            result = sortedByDate(result, \.updated)
        case .created:
            result = sortedByDate(result, \.created)
        case .title:
            result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case nil:
            result = sortedByVaultOrder(result, vault: vault, collections: collections)
        }
        if let limit {
            result = Array(result.prefix(limit))
        }
        return result
    }

    /// Newest first; notes without a readable date go last.
    private func sortedByDate(_ notes: [Note], _ field: KeyPath<Note, String>) -> [Note] {
        notes
            .map { (note: $0, date: parseNoteDate($0[keyPath: field]) ?? .distantPast) }
            .sorted { $0.date > $1.date }
            .map(\.note)
    }

    /// The order the app shows: collections as listed in maho.yaml, and inside each
    /// folder the `order:` of its `_index.md` (unlisted notes follow, by filename).
    private func sortedByVaultOrder(_ notes: [Note], vault: Vault, collections: [Collection]) -> [Note] {
        let byDirectory = Dictionary(grouping: notes) { ($0.relativePath as NSString).deletingLastPathComponent }
        let collectionRank = Dictionary(collections.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        func rank(_ directory: String) -> Int {
            collectionRank[String(directory.split(separator: "/").first ?? "")] ?? Int.max
        }
        let directories = byDirectory.keys.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return directories.flatMap { directory -> [Note] in
            let (order, _) = readDirectoryOrder(at: vault.absolutePath(for: directory))
            return sortByOrder(byDirectory[directory] ?? [], order: order) {
                ($0.relativePath as NSString).lastPathComponent
            }
        }
    }

    // MARK: - Text output

    private func printNotes(_ notes: [Note], collections: [Collection], vaultName: String?) {
        let prefix = vaultName.map { "[\($0)] " } ?? ""
        func printNote(_ note: Note) {
            let tags = note.tags.isEmpty ? "" : " [\(note.tags.joined(separator: ", "))]"
            let date = note.created.isEmpty ? "" : "  \(note.created.prefix(10))"
            print("  \(prefix)\(note.relativePath)")
            print("    \(note.title)\(tags)\(date)")
        }

        // An explicit sort is one flat list; the default order is grouped by collection.
        if sort != nil {
            notes.forEach(printNote)
            return
        }

        let grouped = Dictionary(grouping: notes, by: { $0.collection })
        for coll in collections {
            guard let collNotes = grouped[coll.id], !collNotes.isEmpty else { continue }
            print("\(coll.cliIcon) \(coll.name) (\(coll.id))")
            print(String(repeating: "─", count: 40))
            collNotes.forEach(printNote)
            print()
        }

        // Notes outside any known collection (e.g. at the vault root)
        let knownIds = Set(collections.map(\.id))
        for collId in grouped.keys.filter({ !knownIds.contains($0) }).sorted() {
            print("? \(collId.isEmpty ? "(vault root)" : collId)")
            print(String(repeating: "─", count: 40))
            grouped[collId]?.forEach(printNote)
            print()
        }
    }

    // MARK: - Cross-vault

    private func runAllVaults() throws {
        guard let entries = vaultOption.allVaultEntries(), !entries.isEmpty else {
            if outputOption.json {
                print("{}")
            } else {
                print("No vaults registered. Use `mn vault add` to add one.")
            }
            return
        }

        let store = VaultStore.shared

        if outputOption.json {
            // Emit {"vault1": [...notes], "vault2": [...notes]}
            var result: [String: [NoteOutput]] = [:]
            for entry in entries {
                let vault = Vault(path: store.resolvedPath(for: entry))
                let collections = (try? vault.collections()) ?? []
                let notes = select(filtered((try? vault.allNotes()) ?? []), vault: vault, collections: collections)
                result[entry.name] = notes.map { NoteOutput($0, includeBody: body) }
            }
            try printJSON(result)
            return
        }

        for entry in entries {
            let vault = Vault(path: store.resolvedPath(for: entry))
            let collections = (try? vault.collections()) ?? []
            let notes = select(filtered((try? vault.allNotes()) ?? []), vault: vault, collections: collections)
            if notes.isEmpty { continue }

            print("=== \(entry.name) ===")
            printNotes(notes, collections: collections, vaultName: entry.name)
        }
    }

    /// Collection and tag filters for the cross-vault listing.
    private func filtered(_ notes: [Note]) -> [Note] {
        var result = notes
        if let collection {
            let prefix = collection.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
            result = result.filter { $0.relativePath.hasPrefix(prefix) }
        }
        if let tag {
            result = result.filter { $0.tags.contains(tag) }
        }
        return result
    }
}
