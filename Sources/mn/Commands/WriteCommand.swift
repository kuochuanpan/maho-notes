import ArgumentParser
import Foundation
import MahoNotesKit

struct WriteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "write",
        abstract: "Replace a note's body, or append to it",
        discussion: """
            Frontmatter is kept as it is; only `updated` changes. Give the text with \
            --body, --stdin or --file:

              mn write notes/log.md --append --body "- 14:00 deployed"
              mn write notes/draft.md --stdin < draft-body.md

            Appended text starts a new paragraph, except that a list item appended to a \
            list (or a table row to a table) continues it on the next line. To change \
            part of a note, use `mn edit`.
            """
    )

    @OptionGroup var vaultOption: VaultOption
    @OptionGroup var outputOption: OutputOption

    @Argument(help: "Relative path to the note")
    var path: String

    @OptionGroup var bodyInput: BodyInput

    @Flag(name: .long, help: "Add the text to the end of the body instead of replacing it")
    var append = false

    func run() throws {
        let vault = try vaultOption.writableVault()
        let relativePath = try vault.resolveNotePath(path)
        guard let text = try bodyInput.read() else {
            throw CLIError(
                code: "missing_body",
                message: "No body given",
                hint: "Pass the text with --body, --stdin or --file."
            )
        }

        // An empty pipe or file is far more often a failed command upstream than a wish
        // to blank the note. Clearing a body takes an explicit `--body ""`.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, bodyInput.body == nil || append {
            throw CLIError(
                code: "missing_body",
                message: append ? "Nothing to append: the text is empty" : "The body read from \(bodyInput.stdin ? "standard input" : "the file") is empty",
                hint: append ? nil : "To clear a note's body on purpose, pass --body \"\"."
            )
        }

        try vault.writeNoteBody(relativePath: relativePath, text: text, mode: append ? .append : .replace)

        if outputOption.json {
            try printJSON(NoteActionOutput(
                action: append ? "appended" : "replaced",
                path: relativePath,
                absolutePath: vault.absolutePath(for: relativePath),
                note: vault.noteOutput(relativePath)
            ))
            return
        }
        print(append ? "Appended to: \(relativePath)" : "Wrote: \(relativePath)")
    }
}
