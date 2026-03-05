import ArgumentParser
import Foundation
import MahoNotesKit

struct UnpublishCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unpublish",
        abstract: "Mark a note as private and remove from published site"
    )

    @OptionGroup var vaultOption: VaultOption
    @OptionGroup var outputOption: OutputOption

    @Argument(help: "Relative path to the note")
    var path: String

    func run() throws {
        try vaultOption.validateVaultExists()
        try vaultOption.validateWritable()
        let vault = vaultOption.makeVault()
        let vaultPath = vault.path
        let filePath = (vaultPath as NSString).appendingPathComponent(path)

        guard FileManager.default.fileExists(atPath: filePath) else {
            print("Note not found: \(path)")
            throw ExitCode.failure
        }

        // Set public: false in frontmatter
        try setFrontmatterPublic(filePath: filePath, isPublic: false)

        // Update manifest and remove HTML
        var manifest = (try? PublishManifest.load(from: vaultPath)) ?? PublishManifest()
        let outputPath = (vaultPath as NSString).appendingPathComponent("_site")

        if let entry = manifest.entries[path] {
            let htmlPath = "\(outputPath)/c/\(entry.collection)/\(entry.slug).html"
            try? FileManager.default.removeItem(atPath: htmlPath)
            manifest.entries.removeValue(forKey: path)
        }

        try manifest.save(to: vaultPath)

        if outputOption.json {
            try printJSON(["unpublished": path])
        } else {
            print("Unpublished: \(path)")
        }

        // Git commit + push
        try gitCommitAndPush(vaultPath: vaultPath, message: "unpublish: \(path)")
    }
}
