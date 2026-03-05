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

    @Flag(name: .long, help: "Suppress all interactive prompts (useful for scripting)")
    var nonInteractive: Bool = false

    func run() throws {
        let vaultPath = (vaultOption.resolvedPath as NSString).expandingTildeInPath
        let globalConfigDir = ("~/.maho" as NSString).expandingTildeInPath

        let allFlagsProvided = author != nil && github != nil
        let skipWizard = nonInteractive || allFlagsProvided

        var resolvedAuthor = author ?? ""
        var resolvedGithub = github ?? ""
        var resolvedSkipTutorial = noTutorial

        if !skipWizard {
            print("🔭 Maho Notes — Vault Setup")
            print("")
            print("Setting up a new vault at: \(vaultPath)")
            print("")

            if author == nil {
                print("Author name (leave blank to skip): ", terminator: "")
                resolvedAuthor = readLine() ?? ""
            }

            if github == nil {
                print("GitHub repo for sync (e.g., user/vault, leave blank to skip): ", terminator: "")
                resolvedGithub = readLine() ?? ""
            }

            if !noTutorial {
                print("Include tutorial notes? (Y/n): ", terminator: "")
                let answer = readLine() ?? ""
                resolvedSkipTutorial = (answer == "n" || answer == "N")
            }
        }

        print("Creating vault with:")
        print("  Author: \(resolvedAuthor.isEmpty ? "(none)" : resolvedAuthor)")
        print("  GitHub: \(resolvedGithub.isEmpty ? "(none)" : resolvedGithub)")
        print("  Tutorial: \(resolvedSkipTutorial ? "no" : "yes")")

        try initVault(
            vaultPath: vaultPath,
            authorName: resolvedAuthor,
            githubRepo: resolvedGithub,
            skipTutorial: resolvedSkipTutorial,
            globalConfigDir: globalConfigDir
        )
    }
}
