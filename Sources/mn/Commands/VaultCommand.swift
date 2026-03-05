import ArgumentParser
import Foundation
import MahoNotesKit

struct VaultCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vault",
        abstract: "Manage vaults (list, add, remove, set-primary, info)",
        subcommands: [
            VaultListSubcommand.self,
            VaultAddSubcommand.self,
            VaultRemoveSubcommand.self,
            VaultSetPrimarySubcommand.self,
            VaultInfoSubcommand.self,
        ]
    )
}

// MARK: - mn vault list

struct VaultListSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all registered vaults"
    )

    @OptionGroup var outputOption: OutputOption

    func run() throws {
        let globalConfigDir = ("~/.maho" as NSString).expandingTildeInPath
        guard let registry = try loadRegistry(globalConfigDir: globalConfigDir) else {
            if outputOption.json {
                print("[]")
            } else {
                print("No vaults registered. Use `mn vault add` to add one.")
            }
            return
        }

        if outputOption.json {
            struct VaultListEntry: Encodable {
                let name: String
                let type: String
                let access: String
                let github: String?
                let path: String?
                let resolvedPath: String
                let isPrimary: Bool
            }
            let entries = registry.vaults.map { v in
                VaultListEntry(
                    name: v.name,
                    type: v.type.rawValue,
                    access: v.access.rawValue,
                    github: v.github,
                    path: v.path,
                    resolvedPath: resolvedPath(for: v),
                    isPrimary: v.name == registry.primary
                )
            }
            try printJSON(entries)
            return
        }

        // Human-readable table
        func pad(_ s: String, width: Int) -> String {
            s + String(repeating: " ", count: max(0, width - s.count))
        }

        let nameW = max(4, registry.vaults.map(\.name.count).max() ?? 4)
        let typeW  = max(6, registry.vaults.map(\.type.rawValue.count).max() ?? 6)
        let accessW = max(6, registry.vaults.map(\.access.rawValue.count).max() ?? 6)

        let header = "\(pad("NAME", width: nameW))  \(pad("TYPE", width: typeW))  \(pad("ACCESS", width: accessW))  LOCATION"
        print(header)
        print(String(repeating: "─", count: header.count + 10))

        for vault in registry.vaults {
            let location: String
            switch vault.type {
            case .github:  location = vault.github ?? ""
            case .icloud:  location = "(iCloud)"
            case .local:   location = vault.path ?? ""
            }
            let primary = vault.name == registry.primary ? " *" : ""
            print("\(pad(vault.name, width: nameW))  \(pad(vault.type.rawValue, width: typeW))  \(pad(vault.access.rawValue, width: accessW))  \(location)\(primary)")
        }

        if !registry.vaults.isEmpty {
            print("\n* = primary vault")
        }
    }
}

// MARK: - mn vault add

struct VaultAddSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Register a new vault (--icloud | --github <repo> | --path <local>)"
    )

    @Argument(help: "Name for the vault")
    var name: String

    @Flag(name: .long, help: "Create a new iCloud-backed vault")
    var icloud: Bool = false

    @Option(name: .long, help: "GitHub repo (owner/repo) to clone")
    var github: String?

    @Option(name: .long, help: "Local directory path to register")
    var path: String?

    // Access overrides for --github
    @Flag(name: .long, help: "Force read-only access (skips GitHub API check)")
    var readonly: Bool = false

    @Flag(name: .long, help: "Force read-write access (skips GitHub API check)")
    var readwrite: Bool = false

    @Flag(name: .long, help: "Generate maho.yaml from directory structure even if one exists")
    var `import`: Bool = false

    func validate() throws {
        let modes = [icloud, github != nil, path != nil].filter { $0 }.count
        guard modes == 1 else {
            throw ValidationError("Specify exactly one of --icloud, --github <repo>, or --path <local>")
        }
        if `import` && github == nil {
            throw ValidationError("--import requires --github")
        }
        if (readonly || readwrite) && github == nil && path == nil {
            throw ValidationError("--readonly and --readwrite require --github or --path")
        }
        if readonly && readwrite {
            throw ValidationError("--readonly and --readwrite are mutually exclusive")
        }
    }

    func run() throws {
        let globalConfigDir = ("~/.maho" as NSString).expandingTildeInPath
        if icloud {
            try addICloud(globalConfigDir: globalConfigDir)
        } else if let repo = github {
            try addGitHub(repo: repo, globalConfigDir: globalConfigDir)
        } else if let localPath = path {
            try addLocal(path: localPath, globalConfigDir: globalConfigDir)
        }
    }

    // MARK: iCloud

    private func addICloud(globalConfigDir: String) throws {
        let base = ("~/Library/Mobile Documents/iCloud~com.pcca.mahonotes/Documents/vaults" as NSString).expandingTildeInPath
        let vaultPath = (base as NSString).appendingPathComponent(name)

        try initVault(
            vaultPath: vaultPath,
            authorName: "",
            githubRepo: "",
            skipTutorial: true,
            globalConfigDir: globalConfigDir
        )

        var registry = try loadRegistry(globalConfigDir: globalConfigDir)
            ?? VaultRegistry(primary: name, vaults: [])
        let entry = VaultEntry(name: name, type: .icloud, access: .readWrite)
        try registry.addVault(entry)
        if registry.vaults.count == 1 { registry.primary = name }
        try saveRegistry(registry, globalConfigDir: globalConfigDir)

        print("Vault '\(name)' created at \(vaultPath) and registered.")
    }

    // MARK: GitHub

    private func addGitHub(repo: String, globalConfigDir: String) throws {
        let vaultsDir = (globalConfigDir as NSString).appendingPathComponent("vaults")
        let vaultPath = (vaultsDir as NSString).appendingPathComponent(name)
        let fm = FileManager.default

        if fm.fileExists(atPath: vaultPath) {
            print("Note: \(vaultPath) already exists — skipping clone.")
        } else {
            try fm.createDirectory(atPath: vaultsDir, withIntermediateDirectories: true)
            print("Cloning \(repo)...")
            let cloneURL = "https://github.com/\(repo).git"
            try cloneRepo(url: cloneURL, destination: vaultPath)
            print("Cloned to \(vaultPath)")
        }

        // Determine access
        let access: VaultAccess
        if readonly {
            access = .readOnly
        } else if readwrite {
            access = .readWrite
        } else {
            access = autoDetectAccess(repo: repo)
        }

        // Import mode: generate maho.yaml if missing or --import
        let mahoYamlPath = (vaultPath as NSString).appendingPathComponent("maho.yaml")
        if !fm.fileExists(atPath: mahoYamlPath) || `import` {
            if !fm.fileExists(atPath: mahoYamlPath) {
                print("No maho.yaml found — generating from directory structure (import mode).")
            }
            try generateMahoYaml(at: vaultPath, repo: repo)
        }

        var registry = try loadRegistry(globalConfigDir: globalConfigDir)
            ?? VaultRegistry(primary: name, vaults: [])
        let entry = VaultEntry(name: name, type: .github, github: repo, access: access)
        try registry.addVault(entry)
        if registry.vaults.count == 1 { registry.primary = name }
        try saveRegistry(registry, globalConfigDir: globalConfigDir)

        print("Vault '\(name)' registered (type: github, access: \(access.rawValue))")
    }

    /// Best-effort push-access check via GitHub API. Defaults to read-only on any failure.
    private func autoDetectAccess(repo: String) -> VaultAccess {
        guard let token = try? Auth().resolveToken() else {
            print("Notice: No GitHub token found — defaulting to read-only access.")
            return .readOnly
        }
        guard let url = URL(string: "https://api.github.com/repos/\(repo)") else {
            return .readOnly
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var hasPush = false
        nonisolated(unsafe) var apiError = false

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let perms = json["permissions"] as? [String: Any],
                  let push = perms["push"] as? Bool
            else {
                apiError = true
                return
            }
            hasPush = push
        }.resume()
        semaphore.wait()

        if apiError {
            print("Notice: Could not check GitHub permissions — defaulting to read-only access.")
            return .readOnly
        }
        return hasPush ? .readWrite : .readOnly
    }

    /// Scan top-level directories for .md files and generate a maho.yaml.
    private func generateMahoYaml(at vaultPath: String, repo: String) throws {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: vaultPath)) ?? []
        var collections: [(id: String, name: String)] = []

        for item in contents.sorted() {
            guard !item.hasPrefix(".") else { continue }
            var isDir: ObjCBool = false
            let itemPath = (vaultPath as NSString).appendingPathComponent(item)
            guard fm.fileExists(atPath: itemPath, isDirectory: &isDir), isDir.boolValue else { continue }

            // Check for any .md file inside
            var hasMd = false
            let enumerator = fm.enumerator(atPath: itemPath)
            while let file = enumerator?.nextObject() as? String {
                if file.hasSuffix(".md") { hasMd = true; break }
            }
            guard hasMd else { continue }

            let displayName = item
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
            collections.append((id: item, name: displayName))
        }

        let collectionsYaml: String
        if collections.isEmpty {
            collectionsYaml = "collections: []"
        } else {
            let lines = collections.map { "  - id: \($0.id)\n    name: \($0.name)\n    icon: folder" }
                .joined(separator: "\n")
            collectionsYaml = "collections:\n\(lines)"
        }

        let repoName = repo.split(separator: "/").last.map(String.init) ?? repo
        let yaml = """
        # Generated by mn vault add --import
        author:
          name: ""
          url: ""
        \(collectionsYaml)
        github:
          repo: "\(repo)"
        site:
          domain: ""
          title: \(repoName)
          theme: default
        """

        let mahoYamlPath = (vaultPath as NSString).appendingPathComponent("maho.yaml")
        try yaml.write(toFile: mahoYamlPath, atomically: true, encoding: .utf8)
        print("Generated maho.yaml with \(collections.count) collection(s).")
    }

    // MARK: Local

    private func addLocal(path localPath: String, globalConfigDir: String) throws {
        let expanded = (localPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            throw ValidationError("Path does not exist: \(expanded)")
        }

        let access: VaultAccess = readonly ? .readOnly : .readWrite
        var registry = try loadRegistry(globalConfigDir: globalConfigDir)
            ?? VaultRegistry(primary: name, vaults: [])
        let entry = VaultEntry(name: name, type: .local, path: localPath, access: access)
        try registry.addVault(entry)
        if registry.vaults.count == 1 { registry.primary = name }
        try saveRegistry(registry, globalConfigDir: globalConfigDir)

        print("Vault '\(name)' registered (type: local, path: \(localPath), access: \(access.rawValue))")
    }
}

// MARK: - mn vault remove

struct VaultRemoveSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Unregister a vault (use --delete to also remove files)"
    )

    @Argument(help: "Vault name to remove")
    var name: String

    @Flag(name: .long, help: "Also delete the vault directory from disk")
    var delete: Bool = false

    func run() throws {
        let globalConfigDir = ("~/.maho" as NSString).expandingTildeInPath
        guard var registry = try loadRegistry(globalConfigDir: globalConfigDir) else {
            throw ValidationError("No vault registry found.")
        }
        guard let entry = registry.findVault(named: name) else {
            throw ValidationError("Vault '\(name)' not found.")
        }

        if delete {
            let dir = resolvedPath(for: entry)
            let fm = FileManager.default
            if fm.fileExists(atPath: dir) {
                try fm.removeItem(atPath: dir)
                print("Deleted \(dir)")
            } else {
                print("Directory not found (already deleted?): \(dir)")
            }
        }

        try registry.removeVault(named: name)
        try saveRegistry(registry, globalConfigDir: globalConfigDir)
        print("Vault '\(name)' removed from registry.")
    }
}

// MARK: - mn vault set-primary

struct VaultSetPrimarySubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-primary",
        abstract: "Set the default vault"
    )

    @Argument(help: "Vault name to set as primary")
    var name: String

    func run() throws {
        let globalConfigDir = ("~/.maho" as NSString).expandingTildeInPath
        guard var registry = try loadRegistry(globalConfigDir: globalConfigDir) else {
            throw ValidationError("No vault registry found.")
        }
        try registry.setPrimary(name)
        try saveRegistry(registry, globalConfigDir: globalConfigDir)
        print("Primary vault set to '\(name)'.")
    }
}

// MARK: - mn vault info

struct VaultInfoSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show vault details"
    )

    @Argument(help: "Vault name")
    var name: String

    @OptionGroup var outputOption: OutputOption

    func run() throws {
        let globalConfigDir = ("~/.maho" as NSString).expandingTildeInPath
        guard let registry = try loadRegistry(globalConfigDir: globalConfigDir) else {
            throw ValidationError("No vault registry found.")
        }
        guard let entry = registry.findVault(named: name) else {
            throw ValidationError("Vault '\(name)' not found.")
        }

        let path = resolvedPath(for: entry)
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: path)
        let noteCount = exists ? countNotes(at: path) : 0

        if outputOption.json {
            struct VaultInfo: Encodable {
                let name: String
                let type: String
                let access: String
                let github: String?
                let path: String?
                let resolvedPath: String
                let isPrimary: Bool
                let noteCount: Int
                let exists: Bool
            }
            try printJSON(VaultInfo(
                name: entry.name,
                type: entry.type.rawValue,
                access: entry.access.rawValue,
                github: entry.github,
                path: entry.path,
                resolvedPath: path,
                isPrimary: entry.name == registry.primary,
                noteCount: noteCount,
                exists: exists
            ))
            return
        }

        print("Name:    \(entry.name)\(entry.name == registry.primary ? " (primary)" : "")")
        print("Type:    \(entry.type.rawValue)")
        print("Access:  \(entry.access.rawValue)")
        if let repo = entry.github {
            print("Remote:  https://github.com/\(repo)")
        }
        print("Path:    \(path)")
        print("Exists:  \(exists)")
        print("Notes:   \(noteCount)")
    }

    private func countNotes(at path: String) -> Int {
        let fm = FileManager.default
        let baseURL = URL(fileURLWithPath: path)
        guard let enumerator = fm.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            if url.pathExtension == "md" { count += 1 }
        }
        return count
    }
}

// MARK: - Git clone helper

private func cloneRepo(url: String, destination: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["clone", "--depth", "1", url, destination]

    let errPipe = Pipe()
    process.standardOutput = Pipe()
    process.standardError = errPipe

    try process.run()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw VaultCommandError.cloneFailed(repo: url, message: msg)
    }
}

enum VaultCommandError: Error, CustomStringConvertible {
    case cloneFailed(repo: String, message: String)

    var description: String {
        switch self {
        case .cloneFailed(let repo, let message):
            return "Failed to clone \(repo): \(message)"
        }
    }
}
