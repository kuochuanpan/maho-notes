import ArgumentParser
import MahoNotesKit

struct ShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Display a note with its metadata"
    )

    @OptionGroup var vaultOption: VaultOption
    @OptionGroup var outputOption: OutputOption

    @Argument(help: "Relative path to the note (e.g., japanese/grammar/001-kunyomi-onyomi.md)")
    var path: String

    @Flag(name: .long, help: "Print body content only (no frontmatter/metadata, for piping)")
    var bodyOnly = false

    func run() throws {
        try vaultOption.validateVaultExists()
        let vault = vaultOption.makeVault()
        guard let note = try vault.showNote(relativePath: path) else {
            print("Note not found: \(path)")
            throw ExitCode.failure
        }

        if outputOption.json {
            try printJSON(note)
            return
        }

        if bodyOnly {
            print(note.body)
            return
        }

        // Print metadata header
        print("title:      \(note.title)")
        print("collection: \(note.collection)")
        if !note.tags.isEmpty {
            print("tags:       \(note.tags.joined(separator: ", "))")
        }
        print("created:    \(note.created)")
        print("updated:    \(note.updated)")
        if let author = note.author {
            print("author:     \(author)")
        }
        if let series = note.series {
            print("series:     \(series)")
        }
        if note.isPublic {
            print("public:     true")
        }
        print(String(repeating: "─", count: 60))
        print(note.body)
    }
}
