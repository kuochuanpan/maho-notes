import ArgumentParser
import MahoNotesKit

struct ShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Display a note with its metadata"
    )

    @OptionGroup var vaultOption: VaultOption
    @OptionGroup var outputOption: OutputOption

    @Argument(help: "Relative path to the note (e.g., japanese/grammar/kunyomi-onyomi.md; the .md is optional)")
    var path: String

    @Flag(name: .long, help: "Print body content only (no frontmatter/metadata, for piping)")
    var bodyOnly = false

    func run() throws {
        let vault = try vaultOption.existingVault()
        let relativePath = try vault.resolveNotePath(path)
        guard let note = try vault.showNote(relativePath: relativePath) else {
            throw NoteError.noteNotFound(path, suggestions: [])
        }

        if outputOption.json {
            try printJSON(NoteOutput(note, includeBody: true, absolutePath: vault.absolutePath(for: relativePath)))
            return
        }

        if bodyOnly {
            print(note.body, terminator: note.body.hasSuffix("\n") ? "" : "\n")
            return
        }

        // Print metadata header
        print("path:       \(note.relativePath)")
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
        print(note.body, terminator: note.body.hasSuffix("\n") ? "" : "\n")
    }
}
