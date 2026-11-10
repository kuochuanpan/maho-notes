import ArgumentParser
import Foundation
import MahoNotesKit

struct MoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Move a note to another collection",
        discussion: """
            Moves the file, updates both collections' ordering, and brings along the \
            assets the note references. A note with the same filename in the target \
            gets a numeric suffix.
            """,
        aliases: ["mv"]
    )

    @OptionGroup var vaultOption: VaultOption
    @OptionGroup var outputOption: OutputOption

    @Argument(help: "Relative path to the note")
    var path: String

    @Option(name: .long, help: "Collection path to move the note into (e.g., archive, japanese/grammar)")
    var to: String

    @Flag(name: .long, help: "Create the target collection if it does not exist")
    var createCollection = false

    func run() throws {
        let vault = try vaultOption.writableVault()
        let relativePath = try vault.resolveNotePath(path)
        let target = try vault.normalizedCollectionPath(to)

        let currentCollection = (relativePath as NSString).deletingLastPathComponent
        guard currentCollection != target else {
            throw CLIError(code: "already_there", message: "\(relativePath) is already in \(target)")
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: vault.absolutePath(for: target), isDirectory: &isDirectory)
        if exists, !isDirectory.boolValue {
            throw NoteError.invalidCollection(to, reason: "a file with that name is in the way")
        }
        if !exists {
            guard createCollection else {
                throw NoteError.collectionNotFound(target, available: ((try? vault.collections()) ?? []).map(\.id))
            }
            // A new top-level collection is listed in maho.yaml, like one made in the app.
            if !target.contains("/"),
               FileManager.default.fileExists(atPath: vault.absolutePath(for: "maho.yaml")) {
                try? addCollection(vaultPath: vault.path, id: target, name: target)
            }
        }

        let newPath = try vault.moveNote(relativePath: relativePath, toCollection: target)

        if outputOption.json {
            try printJSON(NoteActionOutput(
                action: "moved",
                path: newPath,
                absolutePath: vault.absolutePath(for: newPath),
                from: relativePath,
                note: vault.noteOutput(newPath)
            ))
            return
        }
        print("Moved: \(relativePath) → \(newPath)")
    }
}
