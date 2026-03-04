import ArgumentParser
import MahoNotesKit

struct CollectionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "collections",
        abstract: "List collections with note counts"
    )

    @OptionGroup var vaultOption: VaultOption

    func run() throws {
        let vault = vaultOption.makeVault()
        let collections = try vault.collections()
        let notes = try vault.allNotes()

        for coll in collections {
            let collNotes = notes.filter { $0.relativePath.hasPrefix(coll.id + "/") }
            let count = collNotes.count

            print("\(coll.icon)  \(coll.name) (\(coll.id)) — \(count) note\(count == 1 ? "" : "s")")
            print("   \(coll.description)")

            // Show series if any
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
