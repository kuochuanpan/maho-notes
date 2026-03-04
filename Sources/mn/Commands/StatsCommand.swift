import ArgumentParser
import MahoNotesKit

struct StatsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "Show vault statistics"
    )

    @OptionGroup var vaultOption: VaultOption

    func run() throws {
        let vault = vaultOption.makeVault()
        let collections = try vault.collections()
        let notes = try vault.allNotes()

        print("Vault Statistics")
        print(String(repeating: "─", count: 40))
        print("Total notes: \(notes.count)")

        // Word count (rough: split by whitespace)
        let totalWords = notes.reduce(0) { $0 + $1.body.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }
        print("Total words: \(totalWords)")
        print()

        // Per-collection
        print("Collections:")
        for coll in collections {
            let collNotes = notes.filter { $0.relativePath.hasPrefix(coll.id + "/") }
            let words = collNotes.reduce(0) { $0 + $1.body.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }
            print("  \(coll.name) (\(coll.id)): \(collNotes.count) notes, \(words) words")
        }
        print()

        // Tags
        var tagCounts: [String: Int] = [:]
        for note in notes {
            for tag in note.tags {
                tagCounts[tag, default: 0] += 1
            }
        }
        if !tagCounts.isEmpty {
            print("Tags:")
            for (tag, count) in tagCounts.sorted(by: { $0.value > $1.value }) {
                print("  \(tag): \(count)")
            }
            print()
        }

        // Series
        var seriesCounts: [String: Int] = [:]
        for note in notes {
            if let series = note.series {
                seriesCounts[series, default: 0] += 1
            }
        }
        if !seriesCounts.isEmpty {
            print("Series:")
            for (series, count) in seriesCounts.sorted(by: { $0.value > $1.value }) {
                print("  \(series): \(count)")
            }
        }
    }
}
