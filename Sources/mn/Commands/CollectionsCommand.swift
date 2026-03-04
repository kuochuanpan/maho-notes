import ArgumentParser
import MahoNotesKit

struct CollectionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "collections",
        abstract: "List collections with note counts"
    )

    @OptionGroup var vaultOption: VaultOption
    @OptionGroup var outputOption: OutputOption

    private struct CollectionInfo: Codable {
        let id: String
        let name: String
        let icon: String
        let description: String
        let noteCount: Int
        let series: [String]
    }

    func run() throws {
        let vault = vaultOption.makeVault()
        let collections = try vault.collections()
        let notes = try vault.allNotes()

        if outputOption.json {
            let infos = collections.map { coll -> CollectionInfo in
                let collNotes = notes.filter { $0.relativePath.hasPrefix(coll.id + "/") }
                let seriesNames = Set(collNotes.compactMap(\.series)).sorted()
                return CollectionInfo(
                    id: coll.id, name: coll.name, icon: coll.icon,
                    description: coll.description, noteCount: collNotes.count,
                    series: seriesNames
                )
            }
            try printJSON(infos)
            return
        }

        for coll in collections {
            let collNotes = notes.filter { $0.relativePath.hasPrefix(coll.id + "/") }
            let count = collNotes.count

            print("\(coll.icon)  \(coll.name) (\(coll.id)) — \(count) note\(count == 1 ? "" : "s")")
            print("   \(coll.description)")

            let seriesNames = Set(collNotes.compactMap(\.series))
            if !seriesNames.isEmpty {
                for series in seriesNames.sorted() {
                    let seriesCount = collNotes.filter { $0.series == series }.count
                    print("   series: \(series) (\(seriesCount))")
                }
            }
            print()
        }
    }
}
