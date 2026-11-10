import ArgumentParser
import Foundation
import MahoNotesKit

struct EditCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Replace exact text in a note's body",
        discussion: """
            Changes part of a note without resending the whole body. The match is exact \
            and case-sensitive, and only the body is searched (use `mn meta` for \
            frontmatter). The text must occur exactly once unless --all is given.

              mn edit notes/plan.md --find "ship Friday" --replace "ship Monday"
            """
    )

    @OptionGroup var vaultOption: VaultOption
    @OptionGroup var outputOption: OutputOption

    @Argument(help: "Relative path to the note")
    var path: String

    // `.unconditional` so text that starts with a dash is taken as the value.
    @Option(name: .long, parsing: .unconditional, help: "Text to find (exact match)")
    var find: String

    @Option(name: .long, parsing: .unconditional, help: "Text to put in its place (may be empty to delete the match)")
    var replace: String

    @Flag(name: .long, help: "Replace every occurrence instead of requiring exactly one")
    var all = false

    func run() throws {
        let vault = try vaultOption.writableVault()
        let relativePath = try vault.resolveNotePath(path)
        let count = try vault.replaceInNoteBody(relativePath: relativePath, find: find, replace: replace, all: all)

        if outputOption.json {
            try printJSON(NoteActionOutput(
                action: "edited",
                path: relativePath,
                absolutePath: vault.absolutePath(for: relativePath),
                replacements: count,
                note: vault.noteOutput(relativePath)
            ))
            return
        }
        print("Edited: \(relativePath) (\(count) replacement\(count == 1 ? "" : "s"))")
    }
}
