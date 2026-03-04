import ArgumentParser
import MahoNotesKit

struct StatsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "Show vault statistics"
    )

    @OptionGroup var vaultOption: VaultOption
    @OptionGroup var outputOption: OutputOption

    private struct Stats: Codable {
        let totalNotes: Int
        let totalWords: Int
        let collections: [CollectionStats]
        let tags: [String: Int]
        let series: [String: Int]
    }

    private struct CollectionStats: Codable {
        let id: String
        let name: String
        let noteCount: Int
        let wordCount: Int
    }

    func run() throws {
        try vaultOption.validateVaultExists()
        let vault = vaultOption.makeVault()
        let collections = try vault.collections()
        let notes = try vault.allNotes()

        let totalWords = notes.reduce(0) { $0 + wordCount($1.body) }

        var tagCounts: [String: Int] = [:]
        for note in notes {
            for tag in note.tags {
                tagCounts[tag, default: 0] += 1
            }
        }

        var seriesCounts: [String: Int] = [:]
        for note in notes {
            if let series = note.series {
                seriesCounts[series, default: 0] += 1
            }
        }

        let collStats = collections.map { coll -> CollectionStats in
            let collNotes = notes.filter { $0.relativePath.hasPrefix(coll.id + "/") }
            let words = collNotes.reduce(0) { $0 + wordCount($1.body) }
            return CollectionStats(id: coll.id, name: coll.name, noteCount: collNotes.count, wordCount: words)
        }

        if outputOption.json {
            let stats = Stats(
                totalNotes: notes.count, totalWords: totalWords,
                collections: collStats, tags: tagCounts, series: seriesCounts
            )
            try printJSON(stats)
            return
        }

        print("Vault Statistics")
        print(String(repeating: "─", count: 40))
        print("Total notes: \(notes.count)")
        print("Total words: \(totalWords)")
        print()

        print("Collections:")
        for cs in collStats {
            print("  \(cs.name) (\(cs.id)): \(cs.noteCount) notes, \(cs.wordCount) words")
        }
        print()

        if !tagCounts.isEmpty {
            print("Tags:")
            for (tag, count) in tagCounts.sorted(by: { $0.value > $1.value }) {
                print("  \(tag): \(count)")
            }
            print()
        }

        if !seriesCounts.isEmpty {
            print("Series:")
            for (series, count) in seriesCounts.sorted(by: { $0.value > $1.value }) {
                print("  \(series): \(count)")
            }
        }
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}
