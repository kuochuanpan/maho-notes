import Foundation

// MARK: - Storage Option

public enum StorageOption: String, Sendable, CaseIterable {
    case icloud
    case local
}

// MARK: - iCloud detection

public func iCloudContainerExists() -> Bool {
    let path = ("~/Library/Mobile Documents/iCloud~dev~pcca~mahonotes" as NSString).expandingTildeInPath
    return FileManager.default.fileExists(atPath: path)
}

// MARK: - Vault root resolution

/// Base path for `.maho` config directory, platform-aware.
///
/// - macOS: `~/Library/Group Containers/group.dev.pcca.mahonotes/`
///   (accessible by both the sandboxed app and the CLI without entitlements)
/// - iOS: `<Documents>/.maho/`
///
/// On macOS, uses `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` first
/// (works correctly in both sandboxed and non-sandboxed contexts). Falls back to the
/// hardcoded path for CLI builds that lack the App Group entitlement.
public func mahoConfigBase() -> String {
    #if os(iOS)
    return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        .appendingPathComponent(".maho").path
    #else
    let groupContainer: String
    if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: mahoAppGroupIdentifier) {
        groupContainer = containerURL.path
    } else {
        // Fallback for CLI without App Group entitlement — direct path works
        // because CLI is not sandboxed, so ~ expands to the real home directory.
        groupContainer = ("~/Library/Group Containers/\(mahoAppGroupIdentifier)" as NSString).expandingTildeInPath
    }
    migrateFromLegacyConfigIfNeeded(to: groupContainer)
    return groupContainer
    #endif
}

/// App Group container identifier used on macOS for shared config between the sandboxed app and CLI.
public let mahoAppGroupIdentifier = "group.dev.pcca.mahonotes"

/// Migrates config files from the legacy `~/.maho/` directory to the App Group container.
///
/// Copies all files without deleting the original. Only runs once — skips if
/// the destination already has a `config.yaml`.
public func migrateFromLegacyConfigIfNeeded(to groupContainer: String? = nil) {
    #if os(macOS)
    let destination = groupContainer ?? ("~/Library/Group Containers/group.dev.pcca.mahonotes" as NSString).expandingTildeInPath
    let legacyDir = ("~/.maho" as NSString).expandingTildeInPath
    let fm = FileManager.default

    // Only migrate if legacy config exists and destination doesn't have config yet
    let legacyConfig = (legacyDir as NSString).appendingPathComponent("config.yaml")
    let destConfig = (destination as NSString).appendingPathComponent("config.yaml")
    guard fm.fileExists(atPath: legacyConfig), !fm.fileExists(atPath: destConfig) else { return }

    do {
        if !fm.fileExists(atPath: destination) {
            try fm.createDirectory(atPath: destination, withIntermediateDirectories: true)
        }
        let contents = try fm.contentsOfDirectory(atPath: legacyDir)
        for item in contents {
            let src = (legacyDir as NSString).appendingPathComponent(item)
            let dst = (destination as NSString).appendingPathComponent(item)
            if !fm.fileExists(atPath: dst) {
                try fm.copyItem(atPath: src, toPath: dst)
            }
        }
        print("Migrated config from ~/.maho/ to App Group container")
    } catch {
        print("Warning: could not migrate config from ~/.maho/: \(error.localizedDescription)")
    }
    #endif
}

public func resolveVaultRoot(storage: StorageOption?) -> String {
    switch storage {
    case .icloud:
        return (iCloudDocumentsBasePath() as NSString).appendingPathComponent("vaults")
    case .local:
        return mahoConfigBase() + "/vaults"
    case nil:
        if iCloudContainerExists() {
            return ("~/Library/Mobile Documents/iCloud~dev~pcca~mahonotes/Documents/vaults" as NSString).expandingTildeInPath
        }
        return mahoConfigBase() + "/vaults"
    }
}

// MARK: - Global config

/// Creates `globalConfigDir/config.yaml` if it doesn't exist.
public func ensureGlobalConfig(globalConfigDir: String) throws {
    let fm = FileManager.default
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
}

// MARK: - Low-level vault file creation

/// Writes vault files (maho.yaml, .maho/, .gitignore, optional tutorial) into `vaultPath`.
/// Does not create a global config or register the vault.
func writeVaultFiles(
    vaultPath: String,
    authorName: String,
    githubRepo: String,
    skipTutorial: Bool,
    tutorialRepoURL: String = "https://github.com/kuochuanpan/maho-getting-started.git"
) throws {
    let fm = FileManager.default

    if !fm.fileExists(atPath: vaultPath) {
        try fm.createDirectory(atPath: vaultPath, withIntermediateDirectories: true)
        print("Created vault at \(vaultPath)")
    }

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

    let mahoDir = (vaultPath as NSString).appendingPathComponent(".maho")
    if !fm.fileExists(atPath: mahoDir) {
        try fm.createDirectory(atPath: mahoDir, withIntermediateDirectories: true)
        print("Created .maho/")
    }

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

    if !skipTutorial {
        let gsDir = (vaultPath as NSString).appendingPathComponent("getting-started")
        if !fm.fileExists(atPath: gsDir) {
            // Try SSH version of tutorial URL first, then the provided URL (usually HTTPS)
            let sshURL = tutorialRepoURL
                .replacingOccurrences(of: "https://github.com/", with: "git@github.com:")
            let urlsToTry = sshURL != tutorialRepoURL ? [sshURL, tutorialRepoURL] : [tutorialRepoURL]

            var cloneSucceeded = false
            #if os(macOS)
            for url in urlsToTry {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["clone", "--depth", "1", url, "getting-started"]
                process.currentDirectoryURL = URL(fileURLWithPath: vaultPath)
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                process.environment = (ProcessInfo.processInfo.environment).merging(
                    ["GIT_TERMINAL_PROMPT": "0"], uniquingKeysWith: { _, new in new }
                )

                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        cloneSucceeded = true
                        break
                    }
                } catch {}
            }
            #endif

            if cloneSucceeded {
                let gitDir = (gsDir as NSString).appendingPathComponent(".git")
                try? fm.removeItem(atPath: gitDir)
                print("Created getting-started/ tutorial notes")
            } else {
                print("Warning: Could not clone tutorial vault. You can add it later with: mn vault add getting-started --github kuochuanpan/maho-getting-started")
            }
        }
    }
}

// MARK: - Registry helper

/// Registers `name` in the vault registry, setting it as primary if it's the first vault.
/// Skips silently if already registered.
func registerVaultEntry(name: String, vaultPath: String, githubRepo: String?, globalConfigDir: String, readOnly: Bool = false, vaultType: VaultType? = nil) throws {
    var registry = (try? loadRegistry(globalConfigDir: globalConfigDir)) ?? VaultRegistry(primary: "", vaults: [])
    guard registry.findVault(named: name) == nil else { return }

    // Determine vault type: explicit > github > cloud sync detection > .device
    let resolvedType: VaultType
    if let explicit = vaultType {
        resolvedType = explicit
    } else if githubRepo != nil && !(githubRepo?.isEmpty ?? true) {
        resolvedType = .github
    } else {
        let cloudSync = loadCloudSyncMode(globalConfigDir: globalConfigDir)
        let iCloudRoot = ("~/Library/Mobile Documents/iCloud~dev~pcca~mahonotes/Documents/vaults" as NSString).expandingTildeInPath
        if cloudSync == .icloud && vaultPath.hasPrefix(iCloudRoot) {
            resolvedType = .icloud
        } else {
            resolvedType = .device
        }
    }

    let entry = VaultEntry(
        name: name,
        type: resolvedType,
        github: githubRepo,
        path: vaultPath,
        access: readOnly ? .readOnly : .readWrite
    )
    try registry.addVault(entry)
    if registry.primary.isEmpty && !readOnly {
        registry.primary = name
    }
    try saveRegistry(registry, globalConfigDir: globalConfigDir)
    print("Registered vault '\(name)' in registry")
}

// MARK: - Public API

/// Creates an empty vault at `vaultRoot/name` and optionally registers it.
///
/// - Parameter skipRegistration: When `true`, the vault is created on disk but not
///   registered in the vault registry. The caller is responsible for calling
///   `VaultStore.registerVault()` separately. Default is `false` for backward compatibility.
public func createEmptyVault(
    name: String,
    vaultRoot: String,
    authorName: String,
    skipTutorial: Bool,
    globalConfigDir: String,
    tutorialRepoURL: String = "https://github.com/kuochuanpan/maho-getting-started.git",
    skipRegistration: Bool = false
) throws {
    let fm = FileManager.default
    if !fm.fileExists(atPath: vaultRoot) {
        try fm.createDirectory(atPath: vaultRoot, withIntermediateDirectories: true)
    }
    let vaultPath = (vaultRoot as NSString).appendingPathComponent(name)

    try ensureGlobalConfig(globalConfigDir: globalConfigDir)
    try writeVaultFiles(
        vaultPath: vaultPath,
        authorName: authorName,
        githubRepo: "",
        skipTutorial: skipTutorial,
        tutorialRepoURL: tutorialRepoURL
    )
    if !skipRegistration {
        try registerVaultEntry(name: name, vaultPath: vaultPath, githubRepo: nil, globalConfigDir: globalConfigDir)
    }
    print("Vault initialized at \(vaultPath)")
}

/// Clones a GitHub vault into `vaultRoot/<name>` and optionally registers it.
/// If the directory already exists, skips cloning and registers as-is.
///
/// - Parameter skipRegistration: When `true`, the vault is cloned but not registered.
///   The caller is responsible for calling `VaultStore.registerVault()` separately.
/// - Returns: The vault name that was registered.
@discardableResult
public func cloneGitHubVault(
    repo: String,
    vaultRoot: String,
    name: String? = nil,
    globalConfigDir: String,
    readOnly: Bool = false,
    skipRegistration: Bool = false
) throws -> String {
    let fm = FileManager.default
    let vaultName = name ?? String(repo.split(separator: "/").last ?? Substring(repo))
    let vaultPath = (vaultRoot as NSString).appendingPathComponent(vaultName)

    if !fm.fileExists(atPath: vaultRoot) {
        try fm.createDirectory(atPath: vaultRoot, withIntermediateDirectories: true)
    }

    try ensureGlobalConfig(globalConfigDir: globalConfigDir)

    if !fm.fileExists(atPath: vaultPath) {
        print("Cloning \(repo)...")

        // Try SSH first (git@github.com:repo.git), then HTTPS
        let urls = [
            "git@github.com:\(repo).git",
            "https://github.com/\(repo).git"
        ]

        var cloneSucceeded = false
        #if os(macOS)
        for url in urls {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["clone", "--depth", "1", url, vaultName]
            process.currentDirectoryURL = URL(fileURLWithPath: vaultRoot)
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            process.environment = (ProcessInfo.processInfo.environment).merging(
                ["GIT_TERMINAL_PROMPT": "0"], uniquingKeysWith: { _, new in new }
            )

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    cloneSucceeded = true
                    break
                }
            } catch {}
        }
        #endif

        if !cloneSucceeded {
            throw VaultInitError.cloneFailed(repo)
        }
        print("Cloned \(repo) to \(vaultPath)")
    } else {
        print("Directory already exists at \(vaultPath), registering...")
    }

    // Detect or generate maho.yaml (import mode)
    let mahoYaml = (vaultPath as NSString).appendingPathComponent("maho.yaml")
    if !fm.fileExists(atPath: mahoYaml) {
        let content = """
        author:
          name: ""
          url: ""
        collections: []
        github:
          repo: "\(repo)"
        site:
          domain: ""
          title: My Notes
          theme: default
        """
        try content.write(toFile: mahoYaml, atomically: true, encoding: .utf8)
        print("Generated maho.yaml (import mode)")
    }

    // Ensure .maho/ and .gitignore
    let mahoDir = (vaultPath as NSString).appendingPathComponent(".maho")
    if !fm.fileExists(atPath: mahoDir) {
        try fm.createDirectory(atPath: mahoDir, withIntermediateDirectories: true)
    }
    let gitignorePath = (vaultPath as NSString).appendingPathComponent(".gitignore")
    if !fm.fileExists(atPath: gitignorePath) {
        try ".maho/\n".write(toFile: gitignorePath, atomically: true, encoding: .utf8)
    } else {
        let existing = try String(contentsOfFile: gitignorePath, encoding: .utf8)
        if !existing.contains(".maho/") && !existing.contains(".maho\n") {
            try (existing + "\n.maho/\n").write(toFile: gitignorePath, atomically: true, encoding: .utf8)
        }
    }

    if !skipRegistration {
        try registerVaultEntry(name: vaultName, vaultPath: vaultPath, githubRepo: repo, globalConfigDir: globalConfigDir, readOnly: readOnly, vaultType: .github)
    }
    print("Vault '\(vaultName)' ready at \(vaultPath)")
    return vaultName
}

public enum VaultInitError: Error, CustomStringConvertible {
    case cloneFailed(String)

    public var description: String {
        switch self {
        case .cloneFailed(let repo): return "Failed to clone repository: \(repo)"
        }
    }
}

// MARK: - Legacy API

/// Core vault initialization logic (legacy). Prefer `createEmptyVault` for new code.
public func initVault(
    vaultPath: String,
    authorName: String,
    githubRepo: String,
    skipTutorial: Bool,
    globalConfigDir: String,
    tutorialRepoURL: String = "https://github.com/kuochuanpan/maho-getting-started.git"
) throws {
    let fm = FileManager.default
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

    try writeVaultFiles(
        vaultPath: vaultPath,
        authorName: authorName,
        githubRepo: githubRepo,
        skipTutorial: skipTutorial,
        tutorialRepoURL: tutorialRepoURL
    )
    print("Vault initialized at \(vaultPath)")
}
