import Foundation
import Yams

/// Token source describes where a GitHub token was found
public enum TokenSource: String, Sendable {
    case environment = "GITHUB_TOKEN environment variable"
    case ghCLI = "gh auth token"
    case stored = ".maho/config.yaml"
}

/// Result of resolving a GitHub auth token
public struct AuthToken: Sendable {
    public let token: String
    public let source: TokenSource

    public init(token: String, source: TokenSource) {
        self.token = token
        self.source = source
    }

    /// Masked display: ghp_xxxx...xxxx (first 4 + last 4 of the token body)
    public var masked: String {
        guard token.count > 8 else { return String(repeating: "*", count: token.count) }
        let prefix = String(token.prefix(8))
        let suffix = String(token.suffix(4))
        return "\(prefix)...\(suffix)"
    }
}

/// Errors from auth operations
public enum AuthError: Error, CustomStringConvertible {
    case noTokenFound
    case ghNotInstalled
    case ghNotLoggedIn(message: String)
    case tokenInvalid(message: String)
    case gitNotInstalled

    public var description: String {
        switch self {
        case .noTokenFound:
            return """
                No GitHub token found. To authenticate, either:
                  1. Set the GITHUB_TOKEN environment variable:
                     export GITHUB_TOKEN=ghp_your_token_here
                  2. Install and log in with GitHub CLI:
                     brew install gh && gh auth login
                  3. Run: mn config auth
                """
        case .ghNotInstalled:
            return """
                GitHub CLI (gh) is not installed. To authenticate, either:
                  1. Set the GITHUB_TOKEN environment variable:
                     export GITHUB_TOKEN=ghp_your_token_here
                  2. Install GitHub CLI:
                     brew install gh && gh auth login
                """
        case .ghNotLoggedIn(let message):
            return """
                GitHub CLI is installed but not logged in.
                Run: gh auth login
                Details: \(message)
                """
        case .tokenInvalid(let message):
            return """
                GitHub token is invalid or expired. Please re-authenticate.
                \(message)
                Run: mn config auth
                """
        case .gitNotInstalled:
            return """
                Git is required for sync. Install Xcode Command Line Tools:
                  xcode-select --install
                """
        }
    }
}

/// Resolve a GitHub token from multiple sources
public struct Auth: Sendable {
    private let vaultPath: String?

    /// Global config directory for device-level settings like auth tokens
    public static var globalConfigDir: String {
        mahoConfigBase()
    }

    /// Initialize with a vault path (optional — auth works without a vault)
    public init(vaultPath: String? = nil) {
        self.vaultPath = vaultPath.map { ($0 as NSString).expandingTildeInPath }
    }

    /// Resolve token from stored config only (no CLI fallback).
    /// Use this in the App where running `gh` CLI is not appropriate (sandboxed, or to require explicit in-app auth).
    public func resolveStoredToken() throws -> AuthToken {
        if let stored = try? loadStoredTokenGlobal(), !stored.isEmpty {
            return AuthToken(token: stored, source: .stored)
        }
        if let vaultPath, let stored = try? loadStoredTokenVault(vaultPath: vaultPath), !stored.isEmpty {
            return AuthToken(token: stored, source: .stored)
        }
        throw AuthError.noTokenFound
    }

    /// Resolve token in priority order: $GITHUB_TOKEN → gh auth token → stored in ~/.maho/config.yaml (or vault .maho/)
    public func resolveToken() throws -> AuthToken {
        // 1. Environment variable
        if let envToken = ProcessInfo.processInfo.environment["GITHUB_TOKEN"],
           !envToken.isEmpty {
            return AuthToken(token: envToken, source: .environment)
        }

        // 2. gh auth token
        if let ghToken = try? resolveFromGhCLI() {
            return ghToken
        }

        // 3. Stored token — check global ~/.maho/config.yaml first, then vault .maho/config.yaml
        if let stored = try? loadStoredTokenGlobal(), !stored.isEmpty {
            return AuthToken(token: stored, source: .stored)
        }
        if let vaultPath, let stored = try? loadStoredTokenVault(vaultPath: vaultPath), !stored.isEmpty {
            return AuthToken(token: stored, source: .stored)
        }

        throw AuthError.noTokenFound
    }

    /// Try to get token from `gh auth token` (macOS only — iOS has no CLI)
    private func resolveFromGhCLI() throws -> AuthToken {
        #if os(macOS)
        let ghPath = findExecutable("gh")
        guard let ghPath else { throw AuthError.ghNotInstalled }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghPath)
        process.arguments = ["auth", "token"]

        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw AuthError.ghNotLoggedIn(message: errMsg)
        }

        guard !output.isEmpty else { throw AuthError.ghNotLoggedIn(message: "empty token") }
        return AuthToken(token: output, source: .ghCLI)
        #else
        throw AuthError.ghNotInstalled
        #endif
    }

    /// Load stored token from global ~/.maho/config.yaml
    private func loadStoredTokenGlobal() throws -> String? {
        let configPath = "\(Auth.globalConfigDir)/config.yaml"
        return try loadTokenFromYaml(path: configPath)
    }

    /// Load stored token from vault's .maho/config.yaml
    private func loadStoredTokenVault(vaultPath: String) throws -> String? {
        let configPath = "\(vaultPath)/.maho/config.yaml"
        return try loadTokenFromYaml(path: configPath)
    }

    private func loadTokenFromYaml(path: String) throws -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let data = fm.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }
        // Simple YAML parsing for auth.github_token
        // Reuse Config if vault path is available, otherwise parse directly
        guard let yaml = try Yams.load(yaml: content) as? [String: Any],
              let auth = yaml["auth"] as? [String: Any],
              let token = auth["github_token"] as? String else {
            return nil
        }
        return token
    }

    /// Store token in global ~/.maho/config.yaml under auth.github_token
    public func storeToken(_ token: String) throws {
        let configDir = Auth.globalConfigDir
        let configPath = "\(configDir)/config.yaml"
        let fm = FileManager.default

        // Ensure ~/.maho/ exists
        if !fm.fileExists(atPath: configDir) {
            try fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }

        // Load existing config or start fresh
        var yaml: [String: Any] = [:]
        if let data = fm.contents(atPath: configPath),
           let content = String(data: data, encoding: .utf8),
           let existing = try Yams.load(yaml: content) as? [String: Any] {
            yaml = existing
        }

        // Set auth.github_token
        var auth = yaml["auth"] as? [String: Any] ?? [:]
        auth["github_token"] = token
        yaml["auth"] = auth

        // Write back
        let output = try Yams.dump(object: yaml)
        try output.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    /// Validate a token against GitHub API (GET /user)
    public func validateToken(_ token: String) throws {
        let url = URL(string: "https://api.github.com/user")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var responseCode: Int?
        nonisolated(unsafe) var responseError: Error?

        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            responseError = error
            responseCode = (response as? HTTPURLResponse)?.statusCode
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let error = responseError {
            throw AuthError.tokenInvalid(message: error.localizedDescription)
        }

        guard let code = responseCode else {
            throw AuthError.tokenInvalid(message: "No response from GitHub API")
        }

        if code == 401 || code == 403 {
            throw AuthError.tokenInvalid(message: "HTTP \(code) — token rejected by GitHub")
        }
    }
}

// MARK: - Pre-flight Checks

public struct PreflightCheck: Sendable {
    /// Check that git is installed and available (macOS only)
    public static func checkGitInstalled() throws {
        #if os(macOS)
        guard findExecutable("git") != nil else {
            throw AuthError.gitNotInstalled
        }
        #else
        // iOS: git CLI not available, GitHub REST API used instead
        #endif
    }

    /// Check if the vault path is inside an iCloud container
    /// Returns a warning message if iCloud Drive might not be enabled, nil otherwise
    public static func checkICloudStatus(vaultPath: String) -> String? {
        let expanded = (vaultPath as NSString).expandingTildeInPath
        guard expanded.contains("Mobile Documents") else { return nil }

        // Check if the iCloud container directory exists
        let icloudBase = ("~/Library/Mobile Documents" as NSString).expandingTildeInPath
        let fm = FileManager.default
        if !fm.fileExists(atPath: icloudBase) {
            return "Warning: Vault is in an iCloud container but iCloud Drive may not be enabled. Sync may not work as expected."
        }
        return nil
    }
}

/// Find an executable in PATH
#if os(macOS)
func findExecutable(_ name: String) -> String? {
    // Check common paths first
    let commonPaths = [
        "/usr/bin/\(name)",
        "/usr/local/bin/\(name)",
        "/opt/homebrew/bin/\(name)",
    ]
    let fm = FileManager.default
    for path in commonPaths {
        if fm.fileExists(atPath: path) { return path }
    }

    // Search PATH
    if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
        for dir in pathEnv.split(separator: ":") {
            let fullPath = "\(dir)/\(name)"
            if fm.fileExists(atPath: fullPath) { return fullPath }
        }
    }
    return nil
}
#endif
