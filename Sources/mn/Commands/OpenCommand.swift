import ArgumentParser
import Foundation
import MahoNotesKit

struct OpenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open a note in your editor"
    )

    @OptionGroup var vaultOption: VaultOption

    @Argument(help: "Relative path to the note")
    var path: String

    func run() throws {
        let vault = try vaultOption.existingVault()
        let filePath = vault.absolutePath(for: try vault.resolveNotePath(path))

        if let editor = ProcessInfo.processInfo.environment["EDITOR"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [editor, filePath]
            try process.run()
            process.waitUntilExit()
        } else {
            #if os(macOS)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-t", filePath]
            try process.run()
            process.waitUntilExit()
            #else
            throw CLIError(code: "no_editor", message: "Set $EDITOR to open notes in your preferred editor.")
            #endif
        }
    }
}
