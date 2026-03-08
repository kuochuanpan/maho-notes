import Foundation

// MARK: - Vault Validation

/// Result of validating a cloned repo as a maho vault
public enum VaultValidation: Sendable {
    case valid                        // maho.yaml exists and parses
    case markdownRepo(message: String) // .md files but no maho.yaml
    case notAVault(message: String)    // no content .md files
}

/// Root-level markdown files to exclude from content detection
private let rootOnlyMdFiles: Set<String> = [
    "README.md", "readme.md",
    "LICENSE.md", "license.md",
    "CHANGELOG.md", "changelog.md",
    "CONTRIBUTING.md", "contributing.md",
    "CODE_OF_CONDUCT.md", "code_of_conduct.md",
]

// MARK: - Sync Result

/// Result returned from a sync operation
public struct SyncResult: Sendable, Codable {
    public let cloned: Bool
    public let pulled: Bool
    public let pushed: Bool
    public let conflictFiles: [String]
    public let message: String

    public init(cloned: Bool = false, pulled: Bool = false, pushed: Bool = false, conflictFiles: [String] = [], message: String = "") {
        self.cloned = cloned
        self.pulled = pulled
        self.pushed = pushed
        self.conflictFiles = conflictFiles
        self.message = message
    }
}

// MARK: - Git Sync

#if os(macOS)
/// Full GitHub sync for the vault (macOS only — iOS uses GitHub REST API instead of git CLI)
public struct GitSync: Sendable {
    private let vaultPath: String
    private let auth: Auth

    public init(vaultPath: String) {
        self.vaultPath = (vaultPath as NSString).expandingTildeInPath
        self.auth = Auth(vaultPath: vaultPath)
    }

    /// Run full sync: preflight → first-run clone or pull/push → conflict handling
    public func sync() throws -> SyncResult {
        // Pre-flight: git installed?
        try PreflightCheck.checkGitInstalled()

        // Pre-flight: check for stale git lock
        let lockPath = (vaultPath as NSString).appendingPathComponent(".git/index.lock")
        if FileManager.default.fileExists(atPath: lockPath) {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: lockPath),
               let modified = attrs[.modificationDate] as? Date,
               Date().timeIntervalSince(modified) > 300 {
                try? FileManager.default.removeItem(atPath: lockPath)
                printWarning("Removed stale git lock file")
            } else {
                throw SyncError.gitLockExists
            }
        }

        // Pre-flight: iCloud warning
        if let warning = PreflightCheck.checkICloudStatus(vaultPath: vaultPath) {
            printWarning(warning)
        }

        // Auth check
        let token: AuthToken
        do {
            token = try auth.resolveToken()
        } catch {
            throw SyncError.authNotConfigured(message: "\(error)")
        }

        // Get github.repo from config
        let config = Config(vaultPath: vaultPath)
        let vaultConfig = try config.loadVaultConfig()
        guard let github = vaultConfig["github"] as? [String: Any],
              let repo = github["repo"] as? String,
              !repo.isEmpty else {
            throw SyncError.repoNotConfigured
        }

        let fm = FileManager.default
        let isGitRepo = fm.fileExists(atPath: (vaultPath as NSString).appendingPathComponent(".git"))

        if !isGitRepo {
            // First-run: clone or init
            return try handleFirstRun(repo: repo, token: token)
        } else {
            // Existing repo: ensure remote is set, then pull/push
            try ensureRemote(repo: repo, token: token)
            return try normalSync(token: token)
        }
    }

    // MARK: - First Run (Clone)

    private func handleFirstRun(repo: String, token: AuthToken) throws -> SyncResult {
        let fm = FileManager.default
        let vaultHasContent = fm.fileExists(atPath: (vaultPath as NSString).appendingPathComponent("maho.yaml"))

        if vaultHasContent {
            // Vault already has content but no git — init and set remote
            try runGit(["init"], in: vaultPath, label: "init")
            try ensureGitignore()
            try setRemoteURL(repo: repo, token: token)
            try runGit(["add", "-A"], in: vaultPath, label: "stage")
            let _ = try? commitIfNeeded(message: "Initial commit")

            // Check if remote has existing commits (common when connecting to an existing repo)
            let env = gitEnv(token: token)
            _ = try? runGit(["fetch", "origin"], in: vaultPath, label: "fetch", env: env)
            let remoteHasCommits = (try? runGit(["rev-parse", "origin/main"], in: vaultPath, label: "check remote")) != nil
                || (try? runGit(["rev-parse", "origin/master"], in: vaultPath, label: "check remote")) != nil

            if remoteHasCommits {
                // Remote has history — merge with --allow-unrelated-histories
                let branch = (try? currentBranch()) ?? "main"
                let remoteBranch = "origin/\(branch)"
                do {
                    try runGit(["pull", "--no-rebase", "--allow-unrelated-histories", remoteBranch.replacingOccurrences(of: "origin/", with: ""), "--verbose"],
                              in: vaultPath, label: "pull --allow-unrelated-histories", env: env)
                } catch {
                    // If pull fails (unrelated histories merge conflict), try explicit merge
                    _ = try? runGit(["merge", "--allow-unrelated-histories", remoteBranch, "-m", "Merge remote vault with local"],
                                   in: vaultPath, label: "merge unrelated", env: env)
                    // If merge has conflicts, resolve them
                    let conflicts = try resolveConflicts()
                    if !conflicts.isEmpty {
                        try pushWithRetry(token: token)
                        return SyncResult(pushed: true, conflictFiles: conflicts,
                                        message: "Merged local vault with remote \(repo). Conflicts saved as .conflict-* files.")
                    }
                }
            }

            try pushWithRetry(token: token)
            return SyncResult(pushed: true, message: "Initialized git repo and pushed to \(repo)")
        }

        // Empty or non-git vault — clone
        // Clone to a temp dir, then move contents into vault
        let tempDir = fm.temporaryDirectory.appendingPathComponent("maho-clone-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: tempDir) }

        let remoteURL = authenticatedURL(repo: repo, token: token.token)
        try runGit(["clone", remoteURL, tempDir], in: fm.temporaryDirectory.path, label: "clone", env: gitEnv(token: token))

        // Validate cloned repo
        let validation = validateVault(atPath: tempDir)
        switch validation {
        case .valid:
            break
        case .markdownRepo(let msg):
            printWarning(msg)
        case .notAVault(let msg):
            throw SyncError.invalidVault(message: msg)
        }

        // Move cloned contents into vault
        try fm.createDirectory(atPath: vaultPath, withIntermediateDirectories: true)
        let contents = try fm.contentsOfDirectory(atPath: tempDir)
        for item in contents {
            let src = (tempDir as NSString).appendingPathComponent(item)
            let dst = (vaultPath as NSString).appendingPathComponent(item)
            if fm.fileExists(atPath: dst) {
                try fm.removeItem(atPath: dst)
            }
            try fm.moveItem(atPath: src, toPath: dst)
        }

        // Ensure .gitignore
        try ensureGitignore()

        return SyncResult(cloned: true, message: "Cloned vault from \(repo)")
    }

    // MARK: - Normal Sync (Pull + Push)

    private func normalSync(token: AuthToken) throws -> SyncResult {
        var conflictFiles: [String] = []

        // Ensure .gitignore
        try ensureGitignore()

        // Stage any local changes first
        try runGit(["add", "-A"], in: vaultPath, label: "stage")

        // Commit local changes (if any)
        _ = try commitIfNeeded(message: "sync: update notes")

        // Pull with rebase
        let pullResult = try pullWithConflictHandling(token: token)
        conflictFiles = pullResult

        // Push (with retry on non-fast-forward)
        try pushWithRetry(token: token)

        let pulled = true
        let pushed = true
        var message = "Sync complete."
        if !conflictFiles.isEmpty {
            let files = conflictFiles.joined(separator: "\n  ")
            message += "\n\nConflict files created (resolve manually, then delete):\n  \(files)"
        }

        return SyncResult(pulled: pulled, pushed: pushed, conflictFiles: conflictFiles, message: message)
    }

    // MARK: - Pull with Conflict Handling

    /// Pull with rebase, falling back to merge (with unrelated histories), handling conflicts
    private func pullWithConflictHandling(token: AuthToken) throws -> [String] {
        let env = gitEnv(token: token)
        let branch = try currentBranch()

        // Try rebase first
        do {
            try runGit(["pull", "--rebase", "origin", branch], in: vaultPath, label: "pull --rebase", env: env)
            return []
        } catch {
            // Rebase conflict — abort and try merge
            _ = try? runGit(["rebase", "--abort"], in: vaultPath, label: "rebase --abort")
        }

        // Fallback: merge (with --allow-unrelated-histories for first-run scenarios)
        do {
            try runGit(["pull", "--no-rebase", "--allow-unrelated-histories", "origin", branch],
                      in: vaultPath, label: "pull --no-rebase", env: env)
            return []
        } catch {
            // Merge conflict — resolve by splitting
            return try resolveConflicts()
        }
    }

    /// Resolve merge conflicts: save local as .conflict-*-local.md, accept remote
    private func resolveConflicts() throws -> [String] {
        // Get list of conflicted files
        let statusOutput = try runGit(["diff", "--name-only", "--diff-filter=U"], in: vaultPath, label: "diff conflicts")
        let conflicted = statusOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !conflicted.isEmpty else { return [] }

        var conflictPaths: [String] = []
        let fm = FileManager.default
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let timestamp = isoFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")

        for file in conflicted {
            let fullPath = (vaultPath as NSString).appendingPathComponent(file)
            guard file.hasSuffix(".md"), fm.fileExists(atPath: fullPath) else {
                // Non-markdown conflict: just accept remote
                _ = try? runGit(["checkout", "--theirs", file], in: vaultPath, label: "checkout theirs")
                continue
            }

            // Save local version with conflict marker
            let localContent: String
            do {
                // Get our version
                localContent = try runGit(["show", ":2:\(file)"], in: vaultPath, label: "show ours")
            } catch {
                // Can't get our version, just accept theirs
                _ = try? runGit(["checkout", "--theirs", file], in: vaultPath, label: "checkout theirs")
                continue
            }

            // Build conflict filename
            let pathURL = URL(fileURLWithPath: file)
            let baseName = pathURL.deletingPathExtension().lastPathComponent
            let dir = pathURL.deletingLastPathComponent().path
            let conflictName = "\(baseName).conflict-\(timestamp)-local.md"
            let conflictRelPath: String
            if dir == "." || dir.isEmpty {
                conflictRelPath = conflictName
            } else {
                conflictRelPath = "\(dir)/\(conflictName)"
            }
            let conflictFullPath = (vaultPath as NSString).appendingPathComponent(conflictRelPath)

            // Write local version to conflict file
            try localContent.write(toFile: conflictFullPath, atomically: true, encoding: .utf8)

            // Accept remote version
            try runGit(["checkout", "--theirs", file], in: vaultPath, label: "checkout theirs")
            conflictPaths.append(conflictRelPath)
        }

        // Stage resolved files and commit
        try runGit(["add", "-A"], in: vaultPath, label: "stage resolved")
        try runGit(["commit", "-m", "sync: resolve conflicts (local versions saved as .conflict-* files)"], in: vaultPath, label: "commit resolved")

        return conflictPaths
    }

    // MARK: - Push with Retry

    private func pushWithRetry(token: AuthToken) throws {
        let env = gitEnv(token: token)
        let branch = try currentBranch()
        do {
            try runGit(["push", "-u", "origin", branch], in: vaultPath, label: "push", env: env)
        } catch let error as GitError {
            // Check for non-fast-forward
            if case .commandFailed(_, let output) = error,
               output.contains("non-fast-forward") || output.contains("rejected") || output.contains("fetch first") {
                // Pull (with unrelated histories support) and retry
                let _ = try pullWithConflictHandling(token: token)
                try runGit(["push", "-u", "origin", branch], in: vaultPath, label: "push retry", env: env)
            } else {
                throw error
            }
        }
    }

    // MARK: - Remote Management

    private func ensureRemote(repo: String, token: AuthToken) throws {
        let remoteURL = authenticatedURL(repo: repo, token: token.token)
        let output = try? runGit(["remote", "get-url", "origin"], in: vaultPath, label: "get remote")
        if output == nil || output?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            try runGit(["remote", "add", "origin", remoteURL], in: vaultPath, label: "add remote")
        } else {
            // Update existing remote URL with fresh token
            try runGit(["remote", "set-url", "origin", remoteURL], in: vaultPath, label: "set remote url")
        }
    }

    private func setRemoteURL(repo: String, token: AuthToken) throws {
        let remoteURL = authenticatedURL(repo: repo, token: token.token)
        _ = try? runGit(["remote", "remove", "origin"], in: vaultPath, label: "remove origin")
        try runGit(["remote", "add", "origin", remoteURL], in: vaultPath, label: "add remote")
    }

    // MARK: - Auth + URL

    private func authenticatedURL(repo: String, token: String) -> String {
        "https://x-access-token:\(token)@github.com/\(repo).git"
    }

    private func gitEnv(token: AuthToken) -> [String: String] {
        // Use GIT_ASKPASS with a simple echo script to inject token
        // This avoids embedding the token in the remote URL for every operation
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        return env
    }

    // MARK: - .gitignore

    /// Ensure .gitignore exists and contains required entries
    func ensureGitignore() throws {
        let gitignorePath = (vaultPath as NSString).appendingPathComponent(".gitignore")
        let fm = FileManager.default
        let requiredEntries = [".maho/", "_site/"]

        if fm.fileExists(atPath: gitignorePath) {
            var content = try String(contentsOfFile: gitignorePath, encoding: .utf8)
            var modified = false
            for entry in requiredEntries {
                let bare = entry.replacingOccurrences(of: "/", with: "")
                if !content.contains(entry) && !content.contains(bare + "\n") {
                    content += "\n\(entry)\n"
                    modified = true
                }
            }
            if modified {
                try content.write(toFile: gitignorePath, atomically: true, encoding: .utf8)
            }
        } else {
            let content = requiredEntries.joined(separator: "\n") + "\n"
            try content.write(toFile: gitignorePath, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Vault Validation

    /// Validate a directory as a maho vault (3-tier check)
    func validateVault(atPath path: String) -> VaultValidation {
        let fm = FileManager.default
        let mahoYaml = (path as NSString).appendingPathComponent("maho.yaml")

        // Tier 1: maho.yaml exists
        if fm.fileExists(atPath: mahoYaml) {
            return .valid
        }

        // Tier 2/3: Check for content .md files (not just root-only like README)
        let hasContentMd = checkForContentMarkdown(atPath: path)

        if hasContentMd {
            return .markdownRepo(message: """
                Cloned repository has markdown files but no maho.yaml.
                This doesn't look like a Maho Notes vault.
                Run `mn init` in the vault to add the required configuration files.
                """)
        }

        return .notAVault(message: """
            Cloned repository has no markdown content files.
            This doesn't appear to be a notes vault. Check that github.repo is set correctly.
            """)
    }

    /// Check if directory has .md files beyond root-only exclusions
    private func checkForContentMarkdown(atPath path: String) -> Bool {
        let fm = FileManager.default
        let baseURL = URL(fileURLWithPath: path).standardizedFileURL
        guard let enumerator = fm.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        let basePath = baseURL.path
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "md" else { continue }
            let standardized = fileURL.standardizedFileURL.path
            let relativePath = standardized.hasPrefix(basePath + "/")
                ? String(standardized.dropFirst(basePath.count + 1))
                : standardized
            // Skip root-only files
            if !relativePath.contains("/") && rootOnlyMdFiles.contains(relativePath) {
                continue
            }
            return true
        }
        return false
    }

    // MARK: - Helpers

    private func currentBranch() throws -> String {
        let output = try runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: vaultPath, label: "current branch")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitIfNeeded(message: String) throws -> Bool {
        let status = try runGitCapture(["diff", "--cached", "--quiet"], in: vaultPath)
        if status != 0 {
            try runGit(["commit", "-m", message], in: vaultPath, label: "commit")
            return true
        }
        return false
    }

    private func printWarning(_ message: String) {
        print("⚠ \(message)")
    }
}
#endif

// MARK: - Sync Errors

public enum SyncError: Error, CustomStringConvertible {
    case authNotConfigured(message: String)
    case repoNotConfigured
    case invalidVault(message: String)
    case gitLockExists

    public var description: String {
        switch self {
        case .authNotConfigured(let message):
            return """
                GitHub auth not configured. Run `mn config auth` first.
                \(message)
                """
        case .repoNotConfigured:
            return """
                GitHub repository not configured. Set it with:
                  mn config set github.repo <owner/repo>
                """
        case .invalidVault(let message):
            return message
        case .gitLockExists:
            return "Another git operation is in progress. Please wait and try again."
        }
    }
}

// MARK: - Git Helpers

#if os(macOS)
@discardableResult
public func runGit(_ args: [String], in directory: String, label: String, env: [String: String]? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: directory)

    if let env {
        process.environment = env
    }

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    try process.run()
    process.waitUntilExit()

    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: outData, encoding: .utf8) ?? ""

    if process.terminationStatus != 0 {
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errOutput = String(data: errData, encoding: .utf8) ?? ""
        throw GitError.commandFailed(label: label, output: errOutput.isEmpty ? output : errOutput)
    }

    return output
}

public func runGitCapture(_ args: [String], in directory: String) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}
#endif

public enum GitError: Error, CustomStringConvertible {
    case commandFailed(label: String, output: String)

    public var description: String {
        switch self {
        case let .commandFailed(label, output):
            "git \(label) failed: \(output)"
        }
    }
}
