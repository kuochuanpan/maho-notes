import ArgumentParser
import Foundation
import MahoNotesKit

struct DeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a note (moves to trash by default)"
    )

    @OptionGroup var vaultOption: VaultOption
    @OptionGroup var outputOption: OutputOption

    @Argument(help: "Relative path to the note")
    var path: String

    @Flag(name: .long, help: "Permanently delete instead of moving to trash")
    var force: Bool = false

    func run() throws {
        let vault = try vaultOption.writableVault()
        let relativePath = try vault.resolveNotePath(path)
        let trashed = try vault.deleteNote(relativePath: relativePath, permanently: force)

        if outputOption.json {
            try printJSON(NoteActionOutput(
                action: trashed ? "trashed" : "deleted",
                path: relativePath,
                absolutePath: nil
            ))
            return
        }
        print(trashed ? "Moved to trash: \(relativePath)" : "Deleted: \(relativePath)")
    }
}
