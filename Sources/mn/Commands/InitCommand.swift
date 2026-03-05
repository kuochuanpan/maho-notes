import ArgumentParser
import Foundation
import MahoNotesKit

struct InitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create a new vault or initialize missing files"
    )

    @OptionGroup var vaultOption: VaultOption

    @Option(name: .long, help: "Author name to set in maho.yaml")
    var author: String?

    @Option(name: .long, help: "GitHub repo (user/repo) to set in maho.yaml")
    var github: String?

    @Flag(name: .long, help: "Skip creating the getting-started tutorial collection")
    var noTutorial: Bool = false

    func run() throws {
        let vaultPath = (vaultOption.resolvedPath as NSString).expandingTildeInPath
        let globalConfigDir = ("~/.maho" as NSString).expandingTildeInPath

        try initVault(
            vaultPath: vaultPath,
            authorName: author ?? "",
            githubRepo: github ?? "",
            skipTutorial: noTutorial,
            globalConfigDir: globalConfigDir
        )
    }
}
