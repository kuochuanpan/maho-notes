import ArgumentParser
import MahoNotesKit

struct NewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new",
        abstract: "Create a new note"
    )

    @OptionGroup var vaultOption: VaultOption
    @OptionGroup var outputOption: OutputOption

    @Argument(help: "Note title")
    var title: String

    @Option(name: .long, help: "Collection id (e.g., japanese, astronomy)")
    var collection: String

    @Option(name: .long, help: "Comma-separated tags")
    var tags: String?

    @Option(name: .long, help: "Author name")
    var author: String = "kuochuan"

    func run() throws {
        try vaultOption.validateVaultExists()
        try vaultOption.validateWritable()
        let vault = vaultOption.makeVault()
        let tagList = tags?
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            ?? []

        let relPath = try vault.createNote(
            title: title,
            collection: collection,
            tags: tagList,
            author: author
        )
        if outputOption.json {
            try printJSON(["path": relPath])
            return
        }
        print("Created: \(relPath)")
    }
}
