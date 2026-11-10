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

    /// The remote head that the commit in `lastCommitSHA` was pushed on top of, when this
    /// device pushed it. Right after a push GitHub can still answer with that older head;
    /// this is how such a stale answer is recognised. Absent in manifests from older versions.
    public var lastPushParentSHA: String?

    public init(lastCommitSHA: String, lastTreeSHA: String, branch: String, files: [String: String], lastSyncDate: Date = Date(), lastPushParentSHA: String? = nil) {
        self.lastCommitSHA = lastCommitSHA
        self.lastTreeSHA = lastTreeSHA
        self.branch = branch
        self.files = files
        self.lastSyncDate = lastSyncDate
        self.lastPushParentSHA = lastPushParentSHA
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

    // MARK: - Full Sync

    /// How many times one `sync()` starts over when the ground moves under it: another
    /// device pushes between reading the remote and updating it, or a file is saved locally
    /// while its remote version is being fetched.
    private static let maxAttempts = 4

    /// How long after a push a remote head equal to that push's parent is taken for a stale
    /// answer rather than a real rewind of the branch.
    private static let staleReadWindow: TimeInterval = 120

    /// Thrown inside a sync cycle to run it again from the top.
    private struct Restart: Error {
        let reason: String
    }

    /// What one `sync()` did, accumulated over its cycles.
    private struct Progress {
        var updated = 0
        var deleted = 0
        var conflicts: [String] = []
        var merged: [String] = []
        var pushed = false
        var pushSummary = ""
    }

    /// Full sync: bring in what changed on GitHub, then push what changed here.
    ///
    /// Every file is compared three ways — the version both sides last agreed on (the
    /// manifest), the local file, the remote file:
    ///
    /// - changed on one side only: that change is taken (including a deletion);
    /// - changed on both sides, a collection `_index.md`: merged by `CollectionIndexMerge`
    ///   when the two changes are independent;
    /// - changed on both sides otherwise: the remote version wins and the local one is kept
    ///   next to it as a `.conflict-*` copy. An edit beats a deletion in either direction —
    ///   edited remotely and deleted here, the file comes back; edited here and deleted
    ///   remotely, the edit is kept as a conflict copy.
    ///
    /// The push then adds one commit on top of the remote head that was just reconciled
    /// with, and never forces: if another device pushed in the meantime GitHub refuses the
    /// update and the cycle runs again against the new head. (Earlier versions pushed a
    /// snapshot of the local files first, with force — silently undoing whatever other
    /// devices had pushed since this one last pulled.)
    public func sync() async throws -> SyncResult {
        var manifest: SyncManifest
        if SyncManifest.exists(vaultPath: vaultPath) {
            manifest = try SyncManifest.load(vaultPath: vaultPath)
        } else {
            if try scanLocalFiles().isEmpty {
                // Empty vault → clone from remote
                return try await clone()
            }
            // Local content that was never synced: no version both sides agreed on, so a
            // file that exists on both sides and differs is a conflict.
            manifest = SyncManifest(lastCommitSHA: "", lastTreeSHA: "", branch: branch, files: [:])
        }

        var progress = Progress()
        var attempt = 1
        while true {
            do {
                try await runCycle(manifest: &manifest, progress: &progress)
                break
            } catch let restart as Restart {
                guard attempt < Self.maxAttempts else {
                    throw GitHubSyncError.interrupted(restart.reason)
                }
                attempt += 1
            }
        }

        var parts: [String] = []
        if progress.updated > 0 || progress.deleted > 0 {
            parts.append("Pulled: \(progress.updated) updated, \(progress.deleted) deleted.")
        }
        if progress.pushed {
            parts.append("Pushed: \(progress.pushSummary).")
        }
        if parts.isEmpty {
            parts.append("Already up to date.")
        }
        let unresolved = conflictCopies(inVault: vaultPath)
        let message = parts.joined(separator: "\n")
            + SyncResult.resolutionSummary(merged: progress.merged, created: progress.conflicts, unresolved: unresolved)

        return SyncResult(
            // "Pulled" is what tells the app to re-read the vault: anything this sync
            // changed on disk counts.
            pulled: progress.updated > 0 || progress.deleted > 0 || !progress.conflicts.isEmpty || !progress.merged.isEmpty,
            pushed: progress.pushed,
            conflictFiles: progress.conflicts,
            mergedFiles: progress.merged,
            unresolvedConflicts: unresolved,
            message: message
        )
    }

    /// One pass: read the remote head, reconcile the working copy with it, push on top of it.
    private func runCycle(manifest: inout SyncManifest, progress: inout Progress) async throws {
        let fm = FileManager.default

        // 1. Remote state
        let ref = try await client.refs.get(owner: owner, repo: repo, ref: "heads/\(branch)")
        var remoteHead = ref.object.sha
        var remoteTreeSHA = manifest.lastTreeSHA
        var remoteFiles = manifest.files // path → blob SHA

        let staleRead = remoteHead != manifest.lastCommitSHA
            && remoteHead == manifest.lastPushParentSHA
            && Date().timeIntervalSince(manifest.lastSyncDate) < Self.staleReadWindow
        if staleRead {
            // GitHub answered with the head from before this device's last push. Reading
            // that tree as "remote changes" would put the old content back over the files
            // just pushed; the manifest already describes the real head.
            remoteHead = manifest.lastCommitSHA
        } else if remoteHead != manifest.lastCommitSHA {
            let commit = try await client.commits.get(owner: owner, repo: repo, sha: remoteHead)
            guard let treeSHA = commit.tree?.sha else {
                throw GitHubSyncError.invalidRemoteState("Commit has no tree")
            }
            let remoteTree = try await client.trees.get(owner: owner, repo: repo, sha: treeSHA, recursive: true)
            guard remoteTree.truncated != true else {
                // A partial listing would read as "the rest was deleted".
                throw GitHubSyncError.invalidRemoteState("The repository has too many files to list in one request")
            }
            remoteFiles = [:]
            for entry in remoteTree.tree where entry.type == "blob" && !shouldExclude(path: entry.path) {
                if let sha = entry.sha {
                    remoteFiles[entry.path] = sha
                }
            }
            remoteTreeSHA = treeSHA
        }

        // 2. Local state
        try ensureGitignore()
        var localFiles: [String: String] = [:] // path → blob SHA
        for path in try scanLocalFiles().keys {
            localFiles[path] = try localBlobSHA(path)
        }

        // 3. Reconcile each file: base (manifest) vs local vs remote
        let base = manifest.files
        let paths = Set(base.keys).union(localFiles.keys).union(remoteFiles.keys).sorted()
        for path in paths {
            let b = base[path], l = localFiles[path], r = remoteFiles[path]
            if l == r { continue }      // the same on both sides already
            if r == b { continue }      // changed here only → goes out with the push

            let localPath = (vaultPath as NSString).appendingPathComponent(path)

            guard let r else {
                // Deleted remotely.
                try verifyUnchanged(path, expected: l)
                if l == b {
                    try fm.removeItem(atPath: localPath)
                    progress.deleted += 1
                } else if l != nil {
                    // …and edited here: the edit is kept, as a conflict copy.
                    let conflictPath = makeConflictPath(for: path)
                    try fm.moveItem(atPath: localPath, toPath: (vaultPath as NSString).appendingPathComponent(conflictPath))
                    progress.conflicts.append(conflictPath)
                }
                continue
            }

            let remoteData = try await blobData(r)

            if l == b || l == nil {
                // Changed remotely only — or edited remotely and deleted here, where the
                // edit wins and the file comes back.
                try verifyUnchanged(path, expected: l)
                try write(remoteData, to: localPath)
                progress.updated += 1
                continue
            }

            // Changed on both sides, differently.
            if CollectionIndexMerge.isCollectionIndex(path: path),
               let localText = try? String(contentsOfFile: localPath, encoding: .utf8),
               let remoteText = String(data: remoteData, encoding: .utf8) {
                var baseText: String?
                if let b, let data = try? await blobData(b) {
                    baseText = String(data: data, encoding: .utf8)
                }
                if case .merged(let text) = CollectionIndexMerge.merge(base: baseText, local: localText, remote: remoteText) {
                    try verifyUnchanged(path, expected: l)
                    if text != localText {
                        try write(Data(text.utf8), to: localPath)
                    }
                    if !progress.merged.contains(path) {
                        progress.merged.append(path)
                    }
                    continue
                }
            }

            // Remote wins; the local version is kept next to it.
            try verifyUnchanged(path, expected: l)
            let conflictPath = makeConflictPath(for: path)
            try fm.copyItem(atPath: localPath, toPath: (vaultPath as NSString).appendingPathComponent(conflictPath))
            try write(remoteData, to: localPath)
            progress.conflicts.append(conflictPath)
            progress.updated += 1
        }

        // 4. The working copy now contains everything at `remoteHead`: that is the new
        //    base. Saved before pushing, so an interrupted push is not mistaken for remote
        //    changes next time.
        if manifest.lastCommitSHA != remoteHead || manifest.files != remoteFiles {
            manifest.files = remoteFiles
            manifest.lastCommitSHA = remoteHead
            manifest.lastTreeSHA = remoteTreeSHA
            manifest.lastSyncDate = Date()
            try manifest.save(vaultPath: vaultPath)
        }

        // 5. Push: a full tree of the local files (so a deleted file does not survive through
        //    tree inheritance, and files excluded from sync never get in).
        var treeEntries: [CreateTreeEntry] = []
        var pushedFiles: [String: String] = [:]
        var changedCount = 0
        for path in try scanLocalFiles().keys.sorted() {
            let data = try Data(contentsOf: URL(fileURLWithPath: (vaultPath as NSString).appendingPathComponent(path)))
            var sha = Self.gitBlobSHA(of: data)
            if remoteFiles[path] != sha {
                // New or changed — upload exactly the bytes that were hashed
                sha = try await client.blobs.create(owner: owner, repo: repo, request: .base64(data)).sha
                changedCount += 1
            }
            treeEntries.append(.blob(path: path, sha: sha))
            pushedFiles[path] = sha
        }
        let deletedCount = remoteFiles.keys.filter { pushedFiles[$0] == nil }.count

        guard changedCount > 0 || deletedCount > 0 else { return }
        guard !treeEntries.isEmpty, remoteFiles["maho.yaml"] == nil || pushedFiles["maho.yaml"] != nil else {
            // A folder that is no longer a vault (a wiped container, an unmounted volume)
            // must not turn into "delete everything on GitHub": every vault has a maho.yaml.
            throw GitHubSyncError.invalidLocalState("The vault folder has lost its maho.yaml; not pushing its deletion.")
        }

        let newTree = try await client.trees.create(
            owner: owner, repo: repo,
            request: CreateTreeRequest(tree: treeEntries)
        )

        let summary = [
            changedCount > 0 ? "\(changedCount) changed" : nil,
            deletedCount > 0 ? "\(deletedCount) deleted" : nil,
        ].compactMap { $0 }.joined(separator: ", ")

        let newCommit = try await client.commits.create(
            owner: owner, repo: repo,
            request: CreateCommitRequest(
                message: "sync: \(summary)",
                tree: newTree.sha,
                parents: [remoteHead],
                author: CommitPerson(name: committerName, email: committerEmail)
            )
        )

        do {
            // Never forced: the commit sits on the head that was reconciled with above. If
            // that is no longer the head, another device pushed — start over against it.
            _ = try await client.refs.update(
                owner: owner, repo: repo,
                ref: "heads/\(branch)",
                request: UpdateRefRequest(sha: newCommit.sha, force: false)
            )
        } catch let error as GitHubError {
            switch error {
            case .validationFailed, .conflict:
                throw Restart(reason: "GitHub changed while syncing (\(error))")
            default:
                throw error
            }
        }

        manifest.files = pushedFiles
        manifest.lastPushParentSHA = remoteHead
        manifest.lastCommitSHA = newCommit.sha
        manifest.lastTreeSHA = newTree.sha
        manifest.lastSyncDate = Date()
        try manifest.save(vaultPath: vaultPath)

        progress.pushed = true
        progress.pushSummary = summary
    }

    /// A file about to be replaced, moved or deleted must still be what it was when this
    /// cycle looked at it. The app keeps saving while a sync is on the network; taking the
    /// remote version over a file saved in between would lose that save without a trace.
    private func verifyUnchanged(_ path: String, expected: String?) throws {
        let localPath = (vaultPath as NSString).appendingPathComponent(path)
        let current = FileManager.default.fileExists(atPath: localPath) ? try localBlobSHA(path) : nil
        if current != expected {
            throw Restart(reason: "\(path) changed on this device while syncing")
        }
    }

    private func blobData(_ sha: String) async throws -> Data {
        let blob = try await client.blobs.get(owner: owner, repo: repo, sha: sha)
        guard let data = blob.decodedData else {
            throw GitHubSyncError.invalidRemoteState("Could not read file content (blob \(sha))")
        }
        return data
    }

    private func write(_ data: Data, to localPath: String) throws {
        let dirPath = (localPath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: dirPath) {
            try FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        }
        try data.write(to: URL(fileURLWithPath: localPath), options: .atomic)
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
        // A vault that is also synced with the `git` CLI has a `.git` folder.
        if path == ".git" || path.hasPrefix(".git/") { return true }
        for pattern in excludePatterns {
            if path == pattern || path.hasPrefix(pattern + "/") || path.contains("/\(pattern)") || path.contains(pattern) {
                return true
            }
        }
        return false
    }

    /// Git blob SHA of a local file (the same value GitHub reports for it), by path
    /// relative to the vault.
    private func localBlobSHA(_ path: String) throws -> String {
        let fullPath = (vaultPath as NSString).appendingPathComponent(path)
        return Self.gitBlobSHA(of: try Data(contentsOf: URL(fileURLWithPath: fullPath)))
    }

    /// Git blob SHA = SHA-1 of "blob <size>\0<content>"
    static func gitBlobSHA(of data: Data) -> String {
        var hashInput = Data("blob \(data.count)\0".utf8)
        hashInput.append(data)
        return Insecure.SHA1.hash(data: hashInput).map { String(format: "%02x", $0) }.joined()
    }

    /// A conflict copy path for a given original path, not yet taken by another file.
    private func makeConflictPath(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = (path as NSString).deletingLastPathComponent

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let timestamp = isoFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")

        func candidate(_ counter: Int) -> String {
            // The app's rename to `.conflict-{DeviceName}` expects the name to end in `-local`.
            let stamp = counter == 1 ? timestamp : "\(timestamp)-\(counter)"
            let name = "\(baseName).conflict-\(stamp)-local\(ext.isEmpty ? "" : ".\(ext)")"
            return dir.isEmpty ? name : "\(dir)/\(name)"
        }
        var counter = 1
        while FileManager.default.fileExists(atPath: (vaultPath as NSString).appendingPathComponent(candidate(counter))) {
            counter += 1
        }
        return candidate(counter)
    }

    /// Ensure .gitignore has required entries.
    private func ensureGitignore() throws {
        let gitignorePath = (vaultPath as NSString).appendingPathComponent(".gitignore")
        let fm = FileManager.default
        let requiredEntries = syncGitignoreEntries

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
    case invalidLocalState(String)
    case nonFastForward
    /// The sync kept being overtaken — by pushes from other devices or by local saves — and
    /// gave up for now. Nothing is lost; the next sync picks up where this one stopped.
    case interrupted(String)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .noManifest:
            return "No sync manifest found. Run sync to initialize."
        case .invalidRemoteState(let msg):
            return "Invalid remote state: \(msg)"
        case .invalidLocalState(let msg):
            return "Invalid local state: \(msg)"
        case .nonFastForward:
            return "Non-fast-forward update — pull first, then push."
        case .interrupted(let reason):
            return "Sync was interrupted and will be retried: \(reason)"
        }
    }
}
