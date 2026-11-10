import ArgumentParser
import Foundation
import MahoNotesKit

struct MetaCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meta",
        abstract: "Show or modify note frontmatter",
        discussion: """
            Only the fields you change are rewritten; the rest of the frontmatter and \
            the body stay exactly as they are. Settable fields: \
            \(NoteMetadataChanges.settableFields.joined(separator: ", ")).

              mn meta notes/plan.md --set title="Plan: Q4" --add-tag roadmap --unset series
            """
    )

    @OptionGroup var vaultOption: VaultOption
    @OptionGroup var outputOption: OutputOption

    @Argument(help: "Relative path to the note")
    var path: String

    @Option(name: .long, help: "Set a frontmatter field (key=value)")
    var set: [String] = []

    @Option(name: .long, help: "Remove a frontmatter field")
    var unset: [String] = []

    @Option(name: .customLong("add-tag"), help: "Add a tag (repeat the option, or separate tags with commas)")
    var addTags: [String] = []

    @Option(name: .customLong("remove-tag"), help: "Remove a tag (repeat the option, or separate tags with commas)")
    var removeTags: [String] = []

    func run() throws {
        let vault = try vaultOption.existingVault()
        let relativePath = try vault.resolveNotePath(path)

        var changes = NoteMetadataChanges(
            unset: unset,
            addTags: splitTags(addTags),
            removeTags: splitTags(removeTags)
        )
        for pair in set {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else {
                throw CLIError(
                    code: "invalid_arguments",
                    message: "Invalid --set value '\(pair)'",
                    hint: "Use key=value, for example --set title=\"New title\"."
                )
            }
            changes.set.append((String(parts[0]).trimmingCharacters(in: .whitespaces), String(parts[1])))
        }

        if changes.isEmpty {
            try show(vault: vault, relativePath: relativePath)
            return
        }

        try vaultOption.validateWritable()
        let note = try vault.updateNoteMetadata(relativePath: relativePath, changes: changes)

        if outputOption.json {
            try printJSON(NoteActionOutput(
                action: "updated",
                path: relativePath,
                absolutePath: vault.absolutePath(for: relativePath),
                note: NoteOutput(note, includeBody: false)
            ))
            return
        }
        if note.isPublic, changes.set.contains(where: { $0.field == "public" }) {
            print("Note is now public — `mn publish` will include it in the site.")
        }
        print("Updated frontmatter for: \(relativePath)")
    }

    private func show(vault: Vault, relativePath: String) throws {
        let filePath = vault.absolutePath(for: relativePath)
        if outputOption.json {
            guard let note = try parseNote(at: filePath, relativeTo: vault.path) else {
                throw NoteError.noteNotFound(relativePath, suggestions: [])
            }
            // Metadata only — `mn show --json` returns the body.
            try printJSON(NoteOutput(note, includeBody: false, absolutePath: filePath))
            return
        }

        let document = FrontmatterDocument(try String(contentsOfFile: filePath, encoding: .utf8))
        guard document.hasFrontmatter else {
            print("No frontmatter in: \(relativePath)")
            return
        }
        // The frontmatter as written in the file.
        for line in document.lines {
            print(line)
        }
    }
}
