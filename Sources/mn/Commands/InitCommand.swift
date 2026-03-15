import ArgumentParser
import Foundation
import MahoNotesKit

struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Set up Maho Notes or add a new vault"
    )

    @Option(name: .long, help: "Storage location: icloud or local")
    var storage: String?

    @Option(name: .long, help: "Vault name (default: repo name or \"personal\")")
    var name: String?

    @Option(name: .long, help: "Author name")
    var author: String?

    @Option(name: .long, help: "GitHub repo (user/repo) to clone as vault")
    var github: String?

    @Flag(name: .long, help: "Skip creating the getting-started tutorial collection")
    var noTutorial: Bool = false

    @Flag(name: .long, help: "Suppress all interactive prompts (useful for scripting)")
    var nonInteractive: Bool = false

    func run() async throws {
        let globalConfigDir = mahoConfigBase()
        let globalConfigPath = (globalConfigDir as NSString).appendingPathComponent("config.yaml")
        let isFirstTime = !FileManager.default.fileExists(atPath: globalConfigPath)
        let store = VaultStore.shared

        if isFirstTime {
            try await runFirstTimeSetup(globalConfigDir: globalConfigDir, store: store)
        } else {
            try await runExistingSetup(globalConfigDir: globalConfigDir, store: store)
        }
    }

    // MARK: - Mode 1: First-time setup

    private func runFirstTimeSetup(globalConfigDir: String, store: VaultStore) async throws {
        let storageOpt: StorageOption? = storage.flatMap { StorageOption(rawValue: $0) }
        let resolvedGithub = github ?? ""
        let resolvedAuthor = author ?? ""

        if nonInteractive {
            let vaultRoot = resolveVaultRoot(storage: storageOpt)

            // Tutorial vault (unless --no-tutorial)
            if !noTutorial {
                let _ = try? cloneGitHubVault(
                    repo: "kuochuanpan/maho-getting-started", vaultRoot: vaultRoot,
                    name: "getting-started", globalConfigDir: globalConfigDir, readOnly: false
                )
            }

            if !resolvedGithub.isEmpty {
                let vaultName = name ?? String(resolvedGithub.split(separator: "/").last ?? "vault")
                do {
                    let registered = try cloneGitHubVault(
                        repo: resolvedGithub, vaultRoot: vaultRoot, name: vaultName,
                        globalConfigDir: globalConfigDir
                    )
                    printSuccess(vaultName: registered, vaultRoot: vaultRoot)
                } catch {
                    print("Warning: \(error). Run `mn vault add <name> --github \(resolvedGithub)` to retry.")
                }
            } else {
                let vaultName = name ?? "personal"
                try createEmptyVault(
                    name: vaultName, vaultRoot: vaultRoot, authorName: resolvedAuthor,
                    skipTutorial: true,  // tutorial is separate vault now
                    globalConfigDir: globalConfigDir
                )
                printSuccess(vaultName: vaultName, vaultRoot: vaultRoot)
            }
            return
        }

        // Interactive
        print("Welcome to Maho Notes!")
        print("")

        // Step 1: Cloud sync
        var useDeviceVault = false
        if iCloudContainerExists() {
            print("Enable iCloud sync? Syncs vaults across all your Apple devices. [Y/n]: ", terminator: "")
            let ans = readLine() ?? ""
            if ans.lowercased() == "n" {
                useDeviceVault = true
                try await store.setCloudSyncMode(.off)
                print("Cloud Sync disabled. Vaults will be stored locally on this device.")
            }
        }

        // Step 2: Storage location (only when Cloud Sync is ON)
        var chosenStorage = storageOpt
        if !useDeviceVault {
            if chosenStorage == nil {
                if iCloudContainerExists() {
                    let iCloudRoot = resolveVaultRoot(storage: .icloud)
                    let localRoot = resolveVaultRoot(storage: .local)
                    print("")
                    print("Where would you like to store your vaults?")
                    print("  1. iCloud (syncs across Apple devices)")
                    print("     -> \(iCloudRoot)/")
                    print("  2. Local (this machine only)")
                    print("     -> \(localRoot)/")
                    print("Choice [1/2]: ", terminator: "")
                    let choice = readLine() ?? "1"
                    chosenStorage = choice == "2" ? .local : .icloud
                } else {
                    let localRoot = resolveVaultRoot(storage: .local)
                    print("Vaults will be stored at: \(localRoot)/")
                    print("(Install the Maho Notes app for iCloud sync)")
                    chosenStorage = .local
                }
            }
        }
        let vaultRoot = useDeviceVault
            ? (globalConfigDir as NSString).appendingPathComponent("vaults")
            : resolveVaultRoot(storage: chosenStorage)

        var resolvedName = name ?? ""
        var authorInput = resolvedAuthor
        if authorInput.isEmpty {
            print("")
            print("Author name: ", terminator: "")
            authorInput = readLine() ?? ""
        }

        // Step: Tutorial vault (first-time only, separate read-only vault)
        if !noTutorial {
            print("")
            print("Add getting-started tutorial vault? (read-only) [Y/n]: ", terminator: "")
            let tutorialChoice = readLine() ?? "Y"
            if tutorialChoice.lowercased() != "n" {
                do {
                    let _ = try cloneGitHubVault(
                        repo: "kuochuanpan/maho-getting-started", vaultRoot: vaultRoot,
                        name: "getting-started", globalConfigDir: globalConfigDir,
                        readOnly: false
                    )
                    print("Added getting-started tutorial vault")
                } catch {
                    print("Warning: Could not clone tutorial: \(error)")
                    print("You can add it later with: mn vault add getting-started --github kuochuanpan/maho-getting-started --readonly")
                }
            }
        }

        // Step: User's vault (clone or create new)
        print("")
        print("Do you have an existing vault on GitHub? (e.g., user/vault)")
        print("GitHub repo (leave blank to create new): ", terminator: "")
        let githubInput = resolvedGithub.isEmpty ? (readLine() ?? "") : resolvedGithub

        if !githubInput.isEmpty {
            let defaultName = String(githubInput.split(separator: "/").last ?? "vault")
            let vaultName = resolvedName.isEmpty ? defaultName : resolvedName
            do {
                let registered = try cloneGitHubVault(
                    repo: githubInput, vaultRoot: vaultRoot, name: vaultName,
                    globalConfigDir: globalConfigDir
                )
                printSuccess(vaultName: registered, vaultRoot: vaultRoot)
            } catch {
                print("Warning: Could not clone \(githubInput): \(error)")
                print("You can add it later with: mn vault add <name> --github \(githubInput)")
            }
        } else {
            if resolvedName.isEmpty {
                print("")
                print("Vault name [personal]: ", terminator: "")
                let nameInput = readLine() ?? ""
                resolvedName = nameInput.isEmpty ? "personal" : nameInput
            }
            if useDeviceVault {
                // Device vault: create files + register with type .device
                let vaultPath = (vaultRoot as NSString).appendingPathComponent(resolvedName)
                let fm = FileManager.default
                if !fm.fileExists(atPath: vaultRoot) {
                    try fm.createDirectory(atPath: vaultRoot, withIntermediateDirectories: true)
                }
                try initVault(
                    vaultPath: vaultPath, authorName: authorInput,
                    githubRepo: "", skipTutorial: true, globalConfigDir: globalConfigDir
                )
                var registry = (try? await store.loadRegistry())
                    ?? VaultRegistry(primary: resolvedName, vaults: [])
                if registry.findVault(named: resolvedName) == nil {
                    let entry = VaultEntry(name: resolvedName, type: .device, access: .readWrite)
                    try registry.addVault(entry)
                    if registry.primary.isEmpty { registry.primary = resolvedName }
                    try await store.saveRegistry(registry)
                }
            } else {
                try createEmptyVault(
                    name: resolvedName, vaultRoot: vaultRoot, authorName: authorInput,
                    skipTutorial: true,  // tutorial is now a separate vault, not inside user's vault
                    globalConfigDir: globalConfigDir
                )
            }
            printSuccess(vaultName: resolvedName, vaultRoot: vaultRoot)
        }
    }

    // MARK: - Mode 2: Existing setup

    private func runExistingSetup(globalConfigDir: String, store: VaultStore) async throws {
        let storageOpt: StorageOption? = storage.flatMap { StorageOption(rawValue: $0) }
        let resolvedGithub = github ?? ""
        let resolvedAuthor = author ?? ""

        if nonInteractive {
            let vaultRoot = resolveVaultRoot(storage: storageOpt)
            if !resolvedGithub.isEmpty {
                let vaultName = name ?? String(resolvedGithub.split(separator: "/").last ?? "vault")
                do {
                    try cloneGitHubVault(
                        repo: resolvedGithub, vaultRoot: vaultRoot, name: vaultName,
                        globalConfigDir: globalConfigDir
                    )
                } catch {
                    print("Warning: \(error). Run `mn vault add <name> --github \(resolvedGithub)` to retry.")
                }
            } else if let vaultName = name {
                try createEmptyVault(
                    name: vaultName, vaultRoot: vaultRoot, authorName: resolvedAuthor,
                    skipTutorial: noTutorial, globalConfigDir: globalConfigDir
                )
            } else {
                throw ValidationError("In non-interactive mode with existing setup, provide --name or --github")
            }
            return
        }

        // Interactive
        print("Maho Notes is already set up on this machine.")
        print("")
        print("Current vaults:")
        if let registry = try? await store.loadRegistry() {
            for entry in registry.vaults {
                let marker = entry.name == registry.primary ? "*" : " "
                let primaryTag = entry.name == registry.primary ? " (primary)" : ""
                let path = store.resolvedPath(for: entry)
                print("  \(marker) \(entry.name)\(primaryTag) — \(path)")
            }
        } else {
            print("  (no vaults registered)")
        }
        print("")
        print("What would you like to do?")
        print("  1. Add a new vault")
        print("  2. Reconfigure (reset global config)")
        print("  3. Cancel")
        print("Choice [1/2/3]: ", terminator: "")
        let choice = readLine() ?? "3"
        switch choice {
        case "1":
            try addNewVaultInteractive(globalConfigDir: globalConfigDir)
        case "2":
            try reconfigure(globalConfigDir: globalConfigDir)
        default:
            print("Cancelled.")
        }
    }

    private func addNewVaultInteractive(globalConfigDir: String) throws {
        var chosenStorage: StorageOption? = storage.flatMap { StorageOption(rawValue: $0) }
        if chosenStorage == nil && iCloudContainerExists() {
            let iCloudRoot = resolveVaultRoot(storage: .icloud)
            let localRoot = resolveVaultRoot(storage: .local)
            print("")
            print("Where would you like to store this vault?")
            print("  1. iCloud -> \(iCloudRoot)/")
            print("  2. Local  -> \(localRoot)/")
            print("Choice [1/2]: ", terminator: "")
            let choice = readLine() ?? "1"
            chosenStorage = choice == "2" ? .local : .icloud
        }
        let vaultRoot = resolveVaultRoot(storage: chosenStorage)

        print("")
        print("GitHub repo (leave blank for empty vault): ", terminator: "")
        let githubInput = readLine() ?? ""

        if !githubInput.isEmpty {
            let defaultName = String(githubInput.split(separator: "/").last ?? "vault")
            print("Vault name [\(defaultName)]: ", terminator: "")
            let nameInput = readLine() ?? ""
            let vaultName = nameInput.isEmpty ? defaultName : nameInput
            do {
                try cloneGitHubVault(
                    repo: githubInput, vaultRoot: vaultRoot, name: vaultName,
                    globalConfigDir: globalConfigDir
                )
            } catch {
                print("Warning: Could not clone: \(error)")
                print("You can retry with: mn vault add <name> --github \(githubInput)")
            }
        } else {
            print("Vault name [personal]: ", terminator: "")
            let nameInput = readLine() ?? ""
            let vaultName = nameInput.isEmpty ? "personal" : nameInput
            try createEmptyVault(
                name: vaultName, vaultRoot: vaultRoot, authorName: author ?? "",
                skipTutorial: noTutorial, globalConfigDir: globalConfigDir
            )
        }
    }

    private func reconfigure(globalConfigDir: String) throws {
        let configPath = (globalConfigDir as NSString).appendingPathComponent("config.yaml")
        let backupPath = (globalConfigDir as NSString).appendingPathComponent("config.yaml.bak")
        let fm = FileManager.default

        // Back up existing config
        if fm.fileExists(atPath: backupPath) {
            try fm.removeItem(atPath: backupPath)
        }
        if fm.fileExists(atPath: configPath) {
            try fm.moveItem(atPath: configPath, toPath: backupPath)
            print("Backed up config to config.yaml.bak")
        }

        // Only reconfigure global settings (author, storage) — don't create vaults
        print("")
        print("Author name: ", terminator: "")
        let authorInput = readLine() ?? ""

        // Re-create global config with author
        let skeleton: String
        if authorInput.isEmpty {
            skeleton = """
            # Maho Notes — global device config
            # Auth tokens and device-specific settings
            auth: {}
            embed:
              model: builtin
            """
        } else {
            skeleton = """
            # Maho Notes — global device config
            author: \(authorInput)
            auth: {}
            embed:
              model: builtin
            """
        }
        if !fm.fileExists(atPath: globalConfigDir) {
            try fm.createDirectory(atPath: globalConfigDir, withIntermediateDirectories: true)
        }
        try skeleton.write(toFile: configPath, atomically: true, encoding: .utf8)

        print("")
        print("Global config updated at \(configPath)")
        print("")
        print("Your existing vaults are unchanged.")
        print("Run `mn vault list` to see them.")
    }

    private func printSuccess(vaultName: String, vaultRoot: String) {
        let vaultPath = (vaultRoot as NSString).appendingPathComponent(vaultName)
        print("")
        print("Setup complete!")
        print("")
        print("  Vault: \(vaultName) (primary)")
        print("  Path:  \(vaultPath)/")
        print("")
        print("Run `mn list` to see your notes.")
        print("Run `mn vault add <name> --github <repo>` to add more vaults.")
    }
}
