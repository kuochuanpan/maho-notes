import ArgumentParser
import Foundation
import MahoNotesKit

struct DeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a note (moves to trash by default)"
    )

    @OptionGroup var vaultOption: VaultOption

    @Argument(help: "Relative path to the note")
    var path: String

    @Flag(name: .long, help: "Permanently delete instead of moving to trash")
    var force: Bool = false

    func run() throws {
        let vault = vaultOption.makeVault()
        let filePath = (vault.path as NSString).appendingPathComponent(path)
        let fm = FileManager.default

        guard fm.fileExists(atPath: filePath) else {
            print("Note not found: \(path)")
            throw ExitCode.failure
        }

        if force {
            try fm.removeItem(atPath: filePath)
            print("Deleted: \(path)")
        } else {
            #if os(macOS)
            let fileURL = URL(fileURLWithPath: filePath)
            try fm.trashItem(at: fileURL, resultingItemURL: nil)
            print("Moved to trash: \(path)")
            #else
            try fm.removeItem(atPath: filePath)
            print("Deleted: \(path)")
            #endif
        }
    }
}
