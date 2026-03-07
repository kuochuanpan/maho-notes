import Foundation
import GitHubAPI

// MARK: - Errors

public enum GitHubVaultImportError: Error, CustomStringConvertible {
    case invalidRepo(String)
    case cloneFailed(String)

    public var description: String {
        switch self {
        case .invalidRepo(let repo): return "Invalid repository format: \(repo) (expected owner/repo)"
        case .cloneFailed(let repo): return "Failed to clone repository via REST API: \(repo)"
        }
    }
}

// MARK: - Public API

/// Import a GitHub repository as a Maho Notes vault using the REST API.
/// Works on all Apple platforms (no git binary required).
///
/// - Parameter skipRegistration: When `true`, the vault is imported but not registered.
///   The caller is responsible for calling `VaultStore.registerVault()` separately.
@discardableResult
public func importGitHubVaultViaAPI(
    repo: String,
    vaultRoot: String,
    name: String? = nil,
    token: String,
    globalConfigDir: String,
    skipRegistration: Bool = false
) async throws -> String {
    let fm = FileManager.default

    // Parse repo and derive vault name
    let parts = repo.split(separator: "/", maxSplits: 1)
    guard parts.count == 2 else {
        throw GitHubVaultImportError.invalidRepo(repo)
    }
    let vaultName = name ?? String(parts[1])
    let vaultPath = (vaultRoot as NSString).appendingPathComponent(vaultName)

    // Ensure global config
    try ensureGlobalConfig(globalConfigDir: globalConfigDir)

    // Create vault directory if needed
    if !fm.fileExists(atPath: vaultRoot) {
        try fm.createDirectory(atPath: vaultRoot, withIntermediateDirectories: true)
    }
    if !fm.fileExists(atPath: vaultPath) {
        try fm.createDirectory(atPath: vaultPath, withIntermediateDirectories: true)
    }

    // Clone via REST API
    guard let manager = GitHubSyncManager.make(
        ownerRepo: repo,
        vaultPath: vaultPath,
        token: token
    ) else {
        throw GitHubVaultImportError.invalidRepo(repo)
    }

    let _ = try await manager.clone()

    // Generate maho.yaml if not present (repo may not contain one)
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
    }

    // Ensure .maho/ directory
    let mahoDir = (vaultPath as NSString).appendingPathComponent(".maho")
    if !fm.fileExists(atPath: mahoDir) {
        try fm.createDirectory(atPath: mahoDir, withIntermediateDirectories: true)
    }

    // Ensure .gitignore has .maho/ entry
    let gitignorePath = (vaultPath as NSString).appendingPathComponent(".gitignore")
    if !fm.fileExists(atPath: gitignorePath) {
        try ".maho/\n".write(toFile: gitignorePath, atomically: true, encoding: .utf8)
    } else {
        let existing = try String(contentsOfFile: gitignorePath, encoding: .utf8)
        if !existing.contains(".maho/") && !existing.contains(".maho\n") {
            try (existing + "\n.maho/\n").write(toFile: gitignorePath, atomically: true, encoding: .utf8)
        }
    }

    // Register in vault registry
    if !skipRegistration {
        try registerVaultEntry(
            name: vaultName,
            vaultPath: vaultPath,
            githubRepo: repo,
            globalConfigDir: globalConfigDir,
            vaultType: .github
        )
    }

    return vaultName
}
