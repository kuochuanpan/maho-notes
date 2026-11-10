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
        let vault = try vaultOption.writableVault()
        let vaultPath = vault.path
        let path = try vault.resolveNotePath(path)
        let filePath = vault.absolutePath(for: path)

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

        // Git commit + push, before the result is printed (see PublishCommand).
        try gitCommitAndPush(vaultPath: vaultPath, message: "unpublish: \(path)")

        if outputOption.json {
            try printJSON(["unpublished": path])
        } else {
            print("Unpublished: \(path)")
        }
    }
}
