import Foundation

/// Core vault initialization logic. Extracted so it can be tested with temp directories.
public func initVault(
    vaultPath: String,
    authorName: String,
    githubRepo: String,
    skipTutorial: Bool,
    globalConfigDir: String,
    tutorialRepoURL: String = "https://github.com/kuochuanpan/maho-getting-started.git"
) throws {
    let fm = FileManager.default

    // --- Global ~/.maho/ setup ---
    if !fm.fileExists(atPath: globalConfigDir) {
        try fm.createDirectory(atPath: globalConfigDir, withIntermediateDirectories: true)
    }

    let globalConfigPath = (globalConfigDir as NSString).appendingPathComponent("config.yaml")
    if !fm.fileExists(atPath: globalConfigPath) {
        let skeleton = """
        # Maho Notes — global device config
        # Auth tokens and device-specific settings
        auth: {}
        embed:
          model: builtin
        """
        try skeleton.write(toFile: globalConfigPath, atomically: true, encoding: .utf8)
        print("Created ~/.maho/config.yaml")
    }

    // --- Vault directory ---
    if !fm.fileExists(atPath: vaultPath) {
        try fm.createDirectory(atPath: vaultPath, withIntermediateDirectories: true)
        print("Created vault at \(vaultPath)")
    }

    // --- maho.yaml ---
    let mahoYaml = (vaultPath as NSString).appendingPathComponent("maho.yaml")
    if !fm.fileExists(atPath: mahoYaml) {
        let collectionsSection: String
        if skipTutorial {
            collectionsSection = "collections: []"
        } else {
            collectionsSection = """
            collections:
              - id: getting-started
                name: Getting Started
                icon: questionmark.circle
                description: Tutorial — how to use Maho Notes (safe to delete)
            """
        }
        let content = """
        author:
          name: "\(authorName)"
          url: ""
        \(collectionsSection)
        github:
          repo: "\(githubRepo)"
        site:
          domain: ""
          title: My Notes
          theme: default
        """
        try content.write(toFile: mahoYaml, atomically: true, encoding: .utf8)
        print("Created maho.yaml")
    }

    // --- .maho/ directory ---
    let mahoDir = (vaultPath as NSString).appendingPathComponent(".maho")
    if !fm.fileExists(atPath: mahoDir) {
        try fm.createDirectory(atPath: mahoDir, withIntermediateDirectories: true)
        print("Created .maho/")
    }

    // --- .gitignore ---
    let gitignorePath = (vaultPath as NSString).appendingPathComponent(".gitignore")
    if !fm.fileExists(atPath: gitignorePath) {
        try ".maho/\n".write(toFile: gitignorePath, atomically: true, encoding: .utf8)
        print("Created .gitignore")
    } else {
        let existing = try String(contentsOfFile: gitignorePath, encoding: .utf8)
        if !existing.contains(".maho/") && !existing.contains(".maho\n") {
            try (existing + "\n.maho/\n").write(toFile: gitignorePath, atomically: true, encoding: .utf8)
            print("Updated .gitignore with .maho/ entry")
        }
    }

    // --- Tutorial notes (cloned from remote) ---
    if !skipTutorial {
        let gsDir = (vaultPath as NSString).appendingPathComponent("getting-started")
        if !fm.fileExists(atPath: gsDir) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["clone", "--depth", "1", tutorialRepoURL, "getting-started"]
            process.currentDirectoryURL = URL(fileURLWithPath: vaultPath)
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            var cloneSucceeded = false
            do {
                try process.run()
                process.waitUntilExit()
                cloneSucceeded = process.terminationStatus == 0
            } catch {
                // git not installed or other launch failure
            }

            if cloneSucceeded {
                let gitDir = (gsDir as NSString).appendingPathComponent(".git")
                try? fm.removeItem(atPath: gitDir)
                print("Created getting-started/ tutorial notes")
            } else {
                print("Warning: Could not clone tutorial vault. You can add it later with: mn vault add getting-started --github kuochuanpan/maho-getting-started")
            }
        }
    }

    print("Vault initialized at \(vaultPath)")
}
