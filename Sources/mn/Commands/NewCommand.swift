import ArgumentParser
import Foundation
import MahoNotesKit

struct NewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new",
        abstract: "Create a new note, optionally with its body",
        discussion: """
            Without a body the note starts as a `# Title` stub. Pass the body with --body, \
            --stdin or --file to write the whole note in one step:

              mn new "Meeting notes" --collection work --tags "meeting, q4" --stdin <<'EOF'
              ## Decisions
              - Ship on Friday
              EOF

            A `# Title` heading is put above the body unless it already starts with one \
            (or --no-heading is given). The collection must exist; --create-collection \
            makes a new one.
            """
    )

    @OptionGroup var vaultOption: VaultOption
    @OptionGroup var outputOption: OutputOption

    @Argument(help: "Note title")
    var title: String

    @Option(name: .long, help: "Collection path (e.g., japanese, japanese/grammar)")
    var collection: String

    @Option(name: .long, help: "Comma-separated tags")
    var tags: String?

    @Option(name: .long, help: "Author name (default: author.name from the vault config)")
    var author: String?

    @Option(name: .long, help: "Series this note belongs to")
    var series: String?

    @OptionGroup var bodyInput: BodyInput

    @Flag(name: .long, help: "Do not add a `# Title` heading above the body")
    var noHeading = false

    @Option(
        name: .long,
        help: "When a note with the same filename exists: suffix (create name-1.md), error, or skip (keep the existing note)"
    )
    var ifExists: ExistingNotePolicy = .suffix

    @Flag(name: .long, help: "Create the collection if it does not exist")
    var createCollection = false

    func run() throws {
        let vault = try vaultOption.writableVault()
        let tagList = splitTags(tags.map { [$0] } ?? [])

        let result = try vault.createNote(
            title: title,
            collection: collection,
            tags: tagList,
            author: author ?? configuredAuthor(vault: vault),
            series: series,
            body: try bodyInput.read(),
            addHeading: !noHeading,
            ifExists: ifExists,
            createCollection: createCollection
        )

        if outputOption.json {
            try printJSON(NoteActionOutput(
                action: result.created ? "created" : "exists",
                path: result.relativePath,
                absolutePath: vault.absolutePath(for: result.relativePath),
                note: vault.noteOutput(result.relativePath)
            ))
            return
        }
        print(result.created ? "Created: \(result.relativePath)" : "Exists: \(result.relativePath)")
    }

    /// `author.name` from the vault's maho.yaml, if set.
    private func configuredAuthor(vault: Vault) -> String? {
        let config = try? Config(vaultPath: vault.path).loadVaultConfig()
        return (config?["author"] as? [String: Any])?["name"] as? String
    }
}

extension ExistingNotePolicy: ExpressibleByArgument {}
