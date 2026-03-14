import Foundation
import CryptoKit
import GitHubAPI

// MARK: - Sync Manifest

/// Tracks local ↔ remote SHA mapping for REST API-based sync (no .git directory).
///
/// Stored as `.maho/sync-manifest.json` inside the vault.
public struct SyncManifest: Codable, Sendable {
    /// Remote commit SHA at last sync.
    public var lastCommitSHA: String

    /// Remote tree SHA at last sync.
    public var lastTreeSHA: String

    /// Branch name (e.g., "main").
    public var branch: String

    /// File path → blob SHA mapping.
    public var files: [String: String]

    /// Last sync timestamp.
    public var lastSyncDate: Date

    public init(lastCommitSHA: String, lastTreeSHA: String, branch: String, files: [String: String], lastSyncDate: Date = Date()) {
        self.lastCommitSHA = lastCommitSHA
        self.lastTreeSHA = lastTreeSHA
        self.branch = branch
        self.files = files
        self.lastSyncDate = lastSyncDate
    }

    // MARK: - Persistence

    static func manifestPath(vaultPath: String) -> String {
        (vaultPath as NSString).appendingPathComponent(".maho/sync-manifest.json")
    }

    public static func load(vaultPath: String) throws -> SyncManifest {
        let path = manifestPath(vaultPath: vaultPath)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SyncManifest.self, from: data)
    }

    public func save(vaultPath: String) throws {
        let path = SyncManifest.manifestPath(vaultPath: vaultPath)
        let dir = (path as NSString).deletingLastPathComponent
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Check if manifest exists for a vault.
    public static func exists(vaultPath: String) -> Bool {
        FileManager.default.fileExists(atPath: manifestPath(vaultPath: vaultPath))
    }
}

// MARK: - GitHub Sync Manager

/// REST API-based GitHub sync for Apple platforms (iOS, iPadOS, macOS).
///
/// Uses `swift-github-api` package — no git binary required.
/// Tracks state via `SyncManifest` instead of `.git/` directory.
///
/// ```swift
/// let manager = GitHubSyncManager(
///     client: GitHubClient(token: "ghp_..."),
///     owner: "kuochuanpan",
///     repo: "maho-vault",
///     branch: "main",
///     vaultPath: "/path/to/vault"
/// )
/// let result = try await manager.sync()
/// ```
public actor GitHubSyncManager {
    /// GitHub API client.
    private let client: GitHubClient

    /// Repository owner.
    public let owner: String

    /// Repository name.
    public let repo: String

    /// Branch name.
    public let branch: String

    /// Local vault path.
    public let vaultPath: String

    /// Files/directories to exclude from sync.
    private let excludePatterns: Set<String> = [
        ".maho",
        ".DS_Store",
        ".conflict-",
        "_site",
    ]

    /// Committer info for created commits.
    private let committerName: String
    private let committerEmail: String

    public init(
        client: GitHubClient,
        owner: String,
        repo: String,
        branch: String = "main",
        vaultPath: String,
        committerName: String = "Maho Notes",
        committerEmail: String = "mahonotes@users.noreply.github.com"
    ) {
        self.client = client
        self.owner = owner
        self.repo = repo
        self.branch = branch
        self.vaultPath = (vaultPath as NSString).expandingTildeInPath
        self.committerName = committerName
        self.committerEmail = committerEmail
    }

    // MARK: - Clone

    /// Clone a remote repo into the vault directory (initial sync).
    ///
    /// Downloads the full tree and all blobs, creates a SyncManifest.
    public func clone() async throws -> SyncResult {
        let fm = FileManager.default

        // 1. Get branch HEAD
        let ref = try await client.refs.get(owner: owner, repo: repo, ref: "heads/\(branch)")
        let headSHA = ref.object.sha

        // 2. Get commit → tree
        let commit = try await client.commits.get(owner: owner, repo: repo, sha: headSHA)
        guard let treeSHA = commit.tree?.sha else {
            throw GitHubSyncError.invalidRemoteState("Commit has no tree")
        }

        // 3. Get full tree (recursive)
        let tree = try await client.trees.get(owner: owner, repo: repo, sha: treeSHA, recursive: true)

        // 4. Download all blobs and write to disk
        var fileMap: [String: String] = [:] // path → blob SHA

        // Ensure vault directory exists
        try fm.createDirectory(atPath: vaultPath, withIntermediateDirectories: true)

        let blobEntries = tree.tree.filter { $0.type == "blob" && !shouldExclude(path: $0.path) }

        for entry in blobEntries {
            guard let sha = entry.sha else { continue }

            let blob = try await client.blobs.get(owner: owner, repo: repo, sha: sha)
            guard let data = blob.decodedData else { continue }

            let filePath = (vaultPath as NSString).appendingPathComponent(entry.path)
            let dirPath = (filePath as NSString).deletingLastPathComponent
            if !fm.fileExists(atPath: dirPath) {
                try fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
            }

            try data.write(to: URL(fileURLWithPath: filePath))
            fileMap[entry.path] = sha
        }

        // 5. Save manifest
        let manifest = SyncManifest(
            lastCommitSHA: headSHA,
            lastTreeSHA: treeSHA,
            branch: branch,
            files: fileMap
        )
        try manifest.save(vaultPath: vaultPath)

        // 6. Ensure .gitignore has .maho/
        try ensureGitignore()

        return SyncResult(
            cloned: true,
            message: "Cloned \(owner)/\(repo) (\(blobEntries.count) files)"
        )
    }

    // MARK: - Pull

    /// Pull remote changes into the local vault.
    ///
    /// Compares local manifest SHAs with remote tree.
    /// Downloads only changed/new files. Detects conflicts (remote-wins + .conflict-* file).
    public func pull() async throws -> SyncResult {
        guard SyncManifest.exists(vaultPath: vaultPath) else {
            // No manifest = first sync → clone
            return try await clone()
        }

        var manifest = try SyncManifest.load(vaultPath: vaultPath)

        // 1. Get remote HEAD
        let ref = try await client.refs.get(owner: owner, repo: repo, ref: "heads/\(branch)")
        let remoteHeadSHA = ref.object.sha

        // Already up to date?
        if remoteHeadSHA == manifest.lastCommitSHA {
            return SyncResult(message: "Already up to date.")
        }

        // 2. Get remote tree
        let commit = try await client.commits.get(owner: owner, repo: repo, sha: remoteHeadSHA)
        guard let remoteTreeSHA = commit.tree?.sha else {
            throw GitHubSyncError.invalidRemoteState("Commit has no tree")
        }
        let remoteTree = try await client.trees.get(owner: owner, repo: repo, sha: remoteTreeSHA, recursive: true)

        // 3. Build remote file map
        var remoteFiles: [String: String] = [:] // path → blob SHA
        for entry in remoteTree.tree where entry.type == "blob" && !shouldExclude(path: entry.path) {
            if let sha = entry.sha {
                remoteFiles[entry.path] = sha
            }
        }

        // 4. Diff: find changed/new/deleted files
        let fm = FileManager.default
        var conflictFiles: [String] = []
        var updatedCount = 0
        var deletedCount = 0

        // Files changed or added remotely
        for (path, remoteSHA) in remoteFiles {
            let manifestSHA = manifest.files[path]

            if manifestSHA == remoteSHA {
                continue // No remote change
            }

            let localPath = (vaultPath as NSString).appendingPathComponent(path)

            // If file was in manifest (we had it before) but is NOT on local disk,
            // the user intentionally deleted it. Don't re-download — the push that
            // already ran (push-first sync) has removed it from remote.
            if manifestSHA != nil && !fm.fileExists(atPath: localPath) {
                continue
            }

            // Check if local file was also modified (conflict)
            if let manifestSHA, fm.fileExists(atPath: localPath) {
                let localSHA = try computeGitBlobSHA(filePath: localPath)
                if localSHA != manifestSHA {
                    // Both modified → conflict! Save local as .conflict-* file
                    let conflictPath = makeConflictPath(for: path)
                    let conflictFullPath = (vaultPath as NSString).appendingPathComponent(conflictPath)
                    try? fm.copyItem(atPath: localPath, toPath: conflictFullPath)
                    conflictFiles.append(conflictPath)
                }
            }

            // Download remote version (remote-wins)
            let blob = try await client.blobs.get(owner: owner, repo: repo, sha: remoteSHA)
            if let data = blob.decodedData {
                let dirPath = (localPath as NSString).deletingLastPathComponent
                if !fm.fileExists(atPath: dirPath) {
                    try fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
                }
                try data.write(to: URL(fileURLWithPath: localPath))
            }

            manifest.files[path] = remoteSHA
            updatedCount += 1
        }

        // Files deleted remotely
        for path in manifest.files.keys where remoteFiles[path] == nil {
            let localPath = (vaultPath as NSString).appendingPathComponent(path)

            // Check if locally modified before deleting
            if fm.fileExists(atPath: localPath) {
                let localSHA = try? computeGitBlobSHA(filePath: localPath)
                if localSHA != manifest.files[path] {
                    // Locally modified but remotely deleted → save as conflict
                    let conflictPath = makeConflictPath(for: path)
                    let conflictFullPath = (vaultPath as NSString).appendingPathComponent(conflictPath)
                    try? fm.moveItem(atPath: localPath, toPath: conflictFullPath)
                    conflictFiles.append(conflictPath)
                } else {
                    try? fm.removeItem(atPath: localPath)
                }
            }

            manifest.files.removeValue(forKey: path)
            deletedCount += 1
        }

        // 5. Update manifest
        manifest.lastCommitSHA = remoteHeadSHA
        manifest.lastTreeSHA = remoteTreeSHA
        manifest.lastSyncDate = Date()
        try manifest.save(vaultPath: vaultPath)

        var message = "Pulled: \(updatedCount) updated, \(deletedCount) deleted."
        if !conflictFiles.isEmpty {
            let files = conflictFiles.joined(separator: "\n  ")
            message += "\nConflicts (local saved as .conflict-*):\n  \(files)"
        }

        return SyncResult(pulled: true, conflictFiles: conflictFiles, message: message)
    }

    // MARK: - Push

    /// Push local changes to the remote repository.
    ///
    /// Uses **full tree mode** (no `baseTree`): builds a complete tree from local files.
    /// This ensures deleted files don't persist via tree inheritance, and files excluded
    /// from sync (e.g. `_site/`) don't leak into the tree.
    public func push() async throws -> SyncResult {
        guard SyncManifest.exists(vaultPath: vaultPath) else {
            throw GitHubSyncError.noManifest
        }

        var manifest = try SyncManifest.load(vaultPath: vaultPath)

        // 1. Scan local files
        let localFiles = try scanLocalFiles()

        // 2. Build full tree: every local file becomes a tree entry
        var treeEntries: [CreateTreeEntry] = []
        var newBlobCount = 0
        var deletedCount = 0
        var newManifestFiles: [String: String] = [:]

        for (path, _) in localFiles {
            let localPath = (vaultPath as NSString).appendingPathComponent(path)
            let localSHA = try computeGitBlobSHA(filePath: localPath)

            if manifest.files[path] == localSHA {
                // Unchanged — reuse existing SHA (no upload needed)
                treeEntries.append(.blob(path: path, sha: localSHA))
                newManifestFiles[path] = localSHA
            } else {
                // New or changed — upload blob
                let fileData = try Data(contentsOf: URL(fileURLWithPath: localPath))
                let blob = try await client.blobs.create(
                    owner: owner, repo: repo,
                    request: .base64(fileData)
                )

                treeEntries.append(.blob(path: path, sha: blob.sha))
                newManifestFiles[path] = blob.sha
                newBlobCount += 1
            }
        }

        // Count deleted files (in manifest but not on disk)
        for path in manifest.files.keys where localFiles[path] == nil {
            deletedCount += 1
        }

        // Nothing changed?
        if newBlobCount == 0 && deletedCount == 0 {
            return SyncResult(pushed: true, message: "Nothing to push.")
        }

        // 3. Create full tree (no baseTree — only what's in local scan)
        let newTree = try await client.trees.create(
            owner: owner, repo: repo,
            request: CreateTreeRequest(tree: treeEntries)
        )

        // 4. Get current remote HEAD as commit parent (not manifest — avoids stale parent race)
        let currentRef = try await client.refs.get(owner: owner, repo: repo, ref: "heads/\(branch)")
        let parentSHA = currentRef.object.sha

        // 5. Create commit
        let changeDesc = [
            newBlobCount > 0 ? "\(newBlobCount) changed" : nil,
            deletedCount > 0 ? "\(deletedCount) deleted" : nil,
        ].compactMap { $0 }.joined(separator: ", ")

        let newCommit = try await client.commits.create(
            owner: owner, repo: repo,
            request: CreateCommitRequest(
                message: "sync: \(changeDesc)",
                tree: newTree.sha,
                parents: [parentSHA],
                author: CommitPerson(name: committerName, email: committerEmail)
            )
        )

        // 6. Update ref (force = true eliminates non-fast-forward errors;
        //    safe because full tree push is a complete snapshot of local state)
        _ = try await client.refs.update(
            owner: owner, repo: repo,
            ref: "heads/\(branch)",
            request: UpdateRefRequest(sha: newCommit.sha, force: true)
        )

        // 7. Update manifest with new file state
        manifest.files = newManifestFiles
        manifest.lastCommitSHA = newCommit.sha
        manifest.lastTreeSHA = newTree.sha
        manifest.lastSyncDate = Date()
        try manifest.save(vaultPath: vaultPath)

        return SyncResult(
            pushed: true,
            message: "Pushed: \(changeDesc)."
        )
    }

    // MARK: - Full Sync

    /// Full sync: pull → push (with conflict handling).
    public func sync() async throws -> SyncResult {
        if !SyncManifest.exists(vaultPath: vaultPath) {
            // First sync — check if local vault has content
            let localFiles = try scanLocalFiles()
            if localFiles.isEmpty {
                // Empty vault → clone from remote
                return try await clone()
            } else {
                // Local content exists but no manifest — initialize manifest from remote, then push
                return try await initialSyncWithExistingContent()
            }
        }

        // Push-first sync: push local state (including deletions) BEFORE pull.
        // This prevents pull from re-downloading files the user deleted locally.
        // Force-push ensures no non-fast-forward errors.
        let pushResult = try await push()
        let pullResult = try await pull()

        var message = pushResult.message
        if !pullResult.message.contains("up to date") {
            message += "\n" + pullResult.message
        }

        return SyncResult(
            pulled: pullResult.pulled,
            pushed: pushResult.pushed,
            conflictFiles: pullResult.conflictFiles + pushResult.conflictFiles,
            message: message
        )
    }

    // MARK: - Initial Sync with Existing Content

    /// Handle first sync when vault already has local content but no manifest.
    /// Downloads remote state, merges, and pushes.
    private func initialSyncWithExistingContent() async throws -> SyncResult {
        let fm = FileManager.default

        // Get remote state
        let ref = try await client.refs.get(owner: owner, repo: repo, ref: "heads/\(branch)")
        let headSHA = ref.object.sha
        let commit = try await client.commits.get(owner: owner, repo: repo, sha: headSHA)
        guard let treeSHA = commit.tree?.sha else {
            throw GitHubSyncError.invalidRemoteState("Commit has no tree")
        }
        let remoteTree = try await client.trees.get(owner: owner, repo: repo, sha: treeSHA, recursive: true)

        // Build remote file map
        var remoteFiles: [String: String] = [:]
        for entry in remoteTree.tree where entry.type == "blob" && !shouldExclude(path: entry.path) {
            if let sha = entry.sha {
                remoteFiles[entry.path] = sha
            }
        }

        // Download remote-only files, detect conflicts
        var conflictFiles: [String] = []
        var manifestFiles: [String: String] = [:]

        for (path, remoteSHA) in remoteFiles {
            let localPath = (vaultPath as NSString).appendingPathComponent(path)

            if fm.fileExists(atPath: localPath) {
                // Both exist — check if different
                let localSHA = try computeGitBlobSHA(filePath: localPath)
                if localSHA != remoteSHA {
                    // Conflict — save local, use remote
                    let conflictPath = makeConflictPath(for: path)
                    let conflictFullPath = (vaultPath as NSString).appendingPathComponent(conflictPath)
                    try? fm.copyItem(atPath: localPath, toPath: conflictFullPath)
                    conflictFiles.append(conflictPath)

                    // Download remote version
                    let blob = try await client.blobs.get(owner: owner, repo: repo, sha: remoteSHA)
                    if let data = blob.decodedData {
                        try data.write(to: URL(fileURLWithPath: localPath))
                    }
                }
                manifestFiles[path] = remoteSHA
            } else {
                // Remote only — download
                let blob = try await client.blobs.get(owner: owner, repo: repo, sha: remoteSHA)
                if let data = blob.decodedData {
                    let dirPath = (localPath as NSString).deletingLastPathComponent
                    if !fm.fileExists(atPath: dirPath) {
                        try fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
                    }
                    try data.write(to: URL(fileURLWithPath: localPath))
                }
                manifestFiles[path] = remoteSHA
            }
        }

        // Create manifest with remote state
        let manifest = SyncManifest(
            lastCommitSHA: headSHA,
            lastTreeSHA: treeSHA,
            branch: branch,
            files: manifestFiles
        )
        try manifest.save(vaultPath: vaultPath)
        try ensureGitignore()

        // Now push any local-only files
        let pushResult = try await push()

        var message = "Initial sync complete."
        if !conflictFiles.isEmpty {
            let files = conflictFiles.joined(separator: "\n  ")
            message += "\nConflicts (local saved as .conflict-*):\n  \(files)"
        }
        if pushResult.pushed {
            message += "\n" + pushResult.message
        }

        return SyncResult(
            pulled: true,
            pushed: pushResult.pushed,
            conflictFiles: conflictFiles + pushResult.conflictFiles,
            message: message
        )
    }

    // MARK: - Helpers

    /// Scan local vault files (excluding .maho/, .DS_Store, .conflict-*, etc.)
    private func scanLocalFiles() throws -> [String: Bool] {
        let fm = FileManager.default
        let baseURL = URL(fileURLWithPath: vaultPath).standardizedFileURL

        guard let enumerator = fm.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return [:]
        }

        var files: [String: Bool] = [:]
        let basePath = baseURL.path

        for case let fileURL as URL in enumerator {
            // Skip directories — only include regular files
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues?.isRegularFile == true else { continue }

            let fullPath = fileURL.standardizedFileURL.path
            let relativePath = fullPath.hasPrefix(basePath + "/")
                ? String(fullPath.dropFirst(basePath.count + 1))
                : fullPath

            if shouldExclude(path: relativePath) { continue }

            files[relativePath] = true
        }

        return files
    }

    /// Check if a path should be excluded from sync.
    private func shouldExclude(path: String) -> Bool {
        for pattern in excludePatterns {
            if path == pattern || path.hasPrefix(pattern + "/") || path.contains("/\(pattern)") || path.contains(pattern) {
                return true
            }
        }
        return false
    }

    /// Compute git blob SHA for a local file (matches GitHub's SHA computation).
    ///
    /// Git blob SHA = SHA-1 of "blob <size>\0<content>"
    private func computeGitBlobSHA(filePath: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        let header = "blob \(data.count)\0"
        var hashInput = Data(header.utf8)
        hashInput.append(data)

        let digest = Insecure.SHA1.hash(data: hashInput)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Create a conflict file path for a given original path.
    private func makeConflictPath(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent().relativePath

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let timestamp = isoFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")

        let conflictName = "\(baseName).conflict-\(timestamp)-local\(ext.isEmpty ? "" : ".\(ext)")"

        if dir == "." || dir.isEmpty {
            return conflictName
        }
        return "\(dir)/\(conflictName)"
    }

    /// Ensure .gitignore has required entries.
    private func ensureGitignore() throws {
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
}

// MARK: - Errors

public enum GitHubSyncError: Error, LocalizedError, CustomStringConvertible, Sendable {
    case noManifest
    case invalidRemoteState(String)
    case nonFastForward

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .noManifest:
            return "No sync manifest found. Run sync to initialize."
        case .invalidRemoteState(let msg):
            return "Invalid remote state: \(msg)"
        case .nonFastForward:
            return "Non-fast-forward update — pull first, then push."
        }
    }
}
