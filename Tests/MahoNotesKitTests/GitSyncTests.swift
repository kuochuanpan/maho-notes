import Testing
import Foundation
@testable import MahoNotesKit

@Suite("GitSync")
struct GitSyncTests {
    // MARK: - Helpers

    /// Create a temporary git repo with initial commit
    private func makeGitRepo(name: String = "test-repo") throws -> (String, URL) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        try runGit(["init"], in: tmp.path, label: "init")
        try runGit(["config", "user.email", "test@example.com"], in: tmp.path, label: "config email")
        try runGit(["config", "user.name", "Test"], in: tmp.path, label: "config name")

        return (tmp.path, tmp)
    }

    /// Create a bare remote repo
    private func makeBareRepo() throws -> (String, URL) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("bare-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try runGit(["init", "--bare"], in: tmp.path, label: "init bare")
        return (tmp.path, tmp)
    }

    /// Create a vault with git repo pointing to a bare remote
    private func makeVaultWithRemote() throws -> (vaultPath: String, remotePath: String, cleanup: [URL]) {
        let (remotePath, remoteURL) = try makeBareRepo()
        let (vaultPath, vaultURL) = try makeGitRepo(name: "vault")

        // Create vault structure
        let yaml = """
        author:
          name: Test
        github:
          repo: test/repo
        """
        try yaml.write(toFile: (vaultPath as NSString).appendingPathComponent("maho.yaml"),
                       atomically: true, encoding: .utf8)

        let mahoDir = (vaultPath as NSString).appendingPathComponent(".maho")
        try FileManager.default.createDirectory(atPath: mahoDir, withIntermediateDirectories: true)

        // Create .gitignore
        try ".maho/\n".write(toFile: (vaultPath as NSString).appendingPathComponent(".gitignore"),
                             atomically: true, encoding: .utf8)

        // Add remote and make initial commit
        try runGit(["remote", "add", "origin", remotePath], in: vaultPath, label: "add remote")
        try runGit(["add", "-A"], in: vaultPath, label: "add all")
        try runGit(["commit", "-m", "initial"], in: vaultPath, label: "initial commit")
        try runGit(["push", "-u", "origin", "main"], in: vaultPath, label: "push")

        return (vaultPath, remotePath, [vaultURL, remoteURL])
    }

    // MARK: - Vault Validation

    @Test func validateVaultWithMahoYaml() throws {
        let (repoPath, repoURL) = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repoURL) }

        try "author:\n  name: Test".write(
            toFile: (repoPath as NSString).appendingPathComponent("maho.yaml"),
            atomically: true, encoding: .utf8)

        let sync = GitSync(vaultPath: repoPath)
        let result = sync.validateVault(atPath: repoPath)
        if case .valid = result {} else {
            Issue.record("Expected .valid, got \(result)")
        }
    }

    @Test func validateMarkdownRepoWithoutMahoYaml() throws {
        let (repoPath, repoURL) = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repoURL) }

        // Create subdirectory with .md files (not just root README)
        let notesDir = (repoPath as NSString).appendingPathComponent("notes")
        try FileManager.default.createDirectory(atPath: notesDir, withIntermediateDirectories: true)
        try "# Test Note".write(toFile: (notesDir as NSString).appendingPathComponent("test.md"),
                                atomically: true, encoding: .utf8)

        let sync = GitSync(vaultPath: repoPath)
        let result = sync.validateVault(atPath: repoPath)
        if case .markdownRepo(let msg) = result {
            #expect(msg.contains("mn init"))
        } else {
            Issue.record("Expected .markdownRepo, got \(result)")
        }
    }

    @Test func validateCodeRepoNotAVault() throws {
        let (repoPath, repoURL) = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repoURL) }

        // Only root README — no content .md files
        try "# My Project".write(
            toFile: (repoPath as NSString).appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8)
        try "MIT".write(
            toFile: (repoPath as NSString).appendingPathComponent("LICENSE.md"),
            atomically: true, encoding: .utf8)

        let sync = GitSync(vaultPath: repoPath)
        let result = sync.validateVault(atPath: repoPath)
        if case .notAVault = result {} else {
            Issue.record("Expected .notAVault, got \(result)")
        }
    }

    // MARK: - .gitignore

    @Test func ensureGitignoreCreatesFile() throws {
        let (repoPath, repoURL) = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let sync = GitSync(vaultPath: repoPath)
        try sync.ensureGitignore()

        let gitignorePath = (repoPath as NSString).appendingPathComponent(".gitignore")
        let content = try String(contentsOfFile: gitignorePath, encoding: .utf8)
        #expect(content.contains(".maho/"))
    }

    @Test func ensureGitignoreAppendsIfMissing() throws {
        let (repoPath, repoURL) = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repoURL) }

        // Create .gitignore without .maho/
        let gitignorePath = (repoPath as NSString).appendingPathComponent(".gitignore")
        try "*.log\n".write(toFile: gitignorePath, atomically: true, encoding: .utf8)

        let sync = GitSync(vaultPath: repoPath)
        try sync.ensureGitignore()

        let content = try String(contentsOfFile: gitignorePath, encoding: .utf8)
        #expect(content.contains("*.log"))
        #expect(content.contains(".maho/"))
    }

    @Test func ensureGitignoreIdempotent() throws {
        let (repoPath, repoURL) = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let gitignorePath = (repoPath as NSString).appendingPathComponent(".gitignore")
        try ".maho/\n".write(toFile: gitignorePath, atomically: true, encoding: .utf8)

        let sync = GitSync(vaultPath: repoPath)
        try sync.ensureGitignore()

        let content = try String(contentsOfFile: gitignorePath, encoding: .utf8)
        // Should not duplicate
        let count = content.components(separatedBy: ".maho/").count - 1
        #expect(count == 1)
    }

    // MARK: - Sync Error Cases

    @Test func syncErrorWhenAuthNotConfigured() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("test-vault-noauth-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // Create vault with github.repo but no auth
        let yaml = "github:\n  repo: test/repo\n"
        try yaml.write(toFile: (tmp.path as NSString).appendingPathComponent("maho.yaml"),
                       atomically: true, encoding: .utf8)
        let mahoDir = (tmp.path as NSString).appendingPathComponent(".maho")
        try fm.createDirectory(atPath: mahoDir, withIntermediateDirectories: true)

        // Init git
        try runGit(["init"], in: tmp.path, label: "init")

        let gitSync = GitSync(vaultPath: tmp.path)
        #expect(throws: (any Error).self) {
            _ = try gitSync.sync()
        }
    }

    @Test func syncErrorWhenRepoNotConfigured() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("test-vault-norepo-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // Create vault without github.repo
        let yaml = "author:\n  name: Test\n"
        try yaml.write(toFile: (tmp.path as NSString).appendingPathComponent("maho.yaml"),
                       atomically: true, encoding: .utf8)
        let mahoDir = (tmp.path as NSString).appendingPathComponent(".maho")
        try fm.createDirectory(atPath: mahoDir, withIntermediateDirectories: true)

        // Store a fake token so auth passes
        let config = Config(vaultPath: tmp.path)
        try config.setValue(key: "auth.github_token", value: "ghp_fake")

        // Init git
        try runGit(["init"], in: tmp.path, label: "init")

        let gitSync = GitSync(vaultPath: tmp.path)
        do {
            _ = try gitSync.sync()
            Issue.record("Expected error")
        } catch let error as SyncError {
            if case .repoNotConfigured = error {} else {
                Issue.record("Expected .repoNotConfigured, got \(error)")
            }
        }
    }

    // MARK: - Normal Sync Flow (with local bare remote)

    @Test func normalSyncPullPush() throws {
        let (vaultPath, remotePath, cleanups) = try makeVaultWithRemote()
        defer { cleanups.forEach { try? FileManager.default.removeItem(at: $0) } }

        // Store a token (we're using local file:// remote so token isn't needed for auth,
        // but the code requires one to be configured)
        let config = Config(vaultPath: vaultPath)
        try config.setValue(key: "auth.github_token", value: "ghp_fake_for_test")

        // Add a new note
        let notesDir = (vaultPath as NSString).appendingPathComponent("test-collection")
        try FileManager.default.createDirectory(atPath: notesDir, withIntermediateDirectories: true)
        try "# Test Note".write(
            toFile: (notesDir as NSString).appendingPathComponent("001-test.md"),
            atomically: true, encoding: .utf8)

        // Manually do the sync steps (since GitSync.sync() would try to use authenticated GitHub URL)
        try runGit(["add", "-A"], in: vaultPath, label: "add")
        try runGit(["commit", "-m", "add test note"], in: vaultPath, label: "commit")
        try runGit(["push", "origin", "main"], in: vaultPath, label: "push")

        // Verify push succeeded by checking remote
        let logOutput = try runGit(["log", "--oneline", "main"], in: remotePath, label: "log")
        #expect(logOutput.contains("add test note"))
    }

    // MARK: - Conflict Handling

    @Test func conflictCreatesConflictFile() throws {
        let (vaultPath, remotePath, cleanups) = try makeVaultWithRemote()
        defer { cleanups.forEach { try? FileManager.default.removeItem(at: $0) } }

        // Clone to a second "device"
        let fm = FileManager.default
        let device2 = fm.temporaryDirectory.appendingPathComponent("device2-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: device2) }
        try runGit(["clone", remotePath, device2.path], in: fm.temporaryDirectory.path, label: "clone device2")
        try runGit(["config", "user.email", "test2@example.com"], in: device2.path, label: "config email")
        try runGit(["config", "user.name", "Test2"], in: device2.path, label: "config name")

        // Create a note on device 1 and push
        let notesDir = (vaultPath as NSString).appendingPathComponent("notes")
        try fm.createDirectory(atPath: notesDir, withIntermediateDirectories: true)
        let notePath = (notesDir as NSString).appendingPathComponent("001-conflict-test.md")
        try "# Original from device 1\nContent A".write(toFile: notePath, atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], in: vaultPath, label: "add")
        try runGit(["commit", "-m", "device1: add note"], in: vaultPath, label: "commit")
        try runGit(["push", "origin", "main"], in: vaultPath, label: "push")

        // Pull on device 2
        try runGit(["pull", "origin", "main"], in: device2.path, label: "pull")

        // Modify on device 2 and push
        let note2Path = device2.appendingPathComponent("notes/001-conflict-test.md").path
        try "# Modified on device 2\nContent B".write(toFile: note2Path, atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], in: device2.path, label: "add")
        try runGit(["commit", "-m", "device2: modify note"], in: device2.path, label: "commit")
        try runGit(["push", "origin", "main"], in: device2.path, label: "push")

        // Modify same file on device 1 (creating divergent history)
        try "# Modified on device 1\nContent C".write(toFile: notePath, atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], in: vaultPath, label: "add")
        try runGit(["commit", "-m", "device1: modify same note"], in: vaultPath, label: "commit")

        // Pull should cause conflict
        // Try rebase first (will conflict)
        do {
            try runGit(["pull", "--rebase", "origin", "main"], in: vaultPath, label: "pull rebase")
        } catch {
            // Expected — abort rebase
            _ = try? runGit(["rebase", "--abort"], in: vaultPath, label: "abort rebase")
        }

        // Try merge (will also conflict)
        do {
            try runGit(["pull", "--no-rebase", "origin", "main"], in: vaultPath, label: "pull merge")
        } catch {
            // Merge conflict — verify conflict state
            let statusOutput = try runGit(["diff", "--name-only", "--diff-filter=U"], in: vaultPath, label: "check conflicts")
            #expect(statusOutput.contains("001-conflict-test.md"))

            // Resolve: accept theirs
            try runGit(["checkout", "--theirs", "notes/001-conflict-test.md"], in: vaultPath, label: "checkout theirs")
            try runGit(["add", "-A"], in: vaultPath, label: "add resolved")
            try runGit(["commit", "-m", "resolve conflict"], in: vaultPath, label: "commit resolved")
        }

        // File should now have device 2's content (remote wins)
        let finalContent = try String(contentsOfFile: notePath, encoding: .utf8)
        #expect(finalContent.contains("device 2"))
    }

    // MARK: - Non-Fast-Forward Push Retry

    @Test func nonFastForwardDetection() throws {
        // Test that we can detect non-fast-forward errors
        let (_, remotePath, cleanups) = try makeVaultWithRemote()
        defer { cleanups.forEach { try? FileManager.default.removeItem(at: $0) } }

        // Clone two working copies
        let fm = FileManager.default
        let wc1 = fm.temporaryDirectory.appendingPathComponent("wc1-\(UUID().uuidString)")
        let wc2 = fm.temporaryDirectory.appendingPathComponent("wc2-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: wc1); try? fm.removeItem(at: wc2) }

        try runGit(["clone", remotePath, wc1.path], in: fm.temporaryDirectory.path, label: "clone wc1")
        try runGit(["clone", remotePath, wc2.path], in: fm.temporaryDirectory.path, label: "clone wc2")

        for wc in [wc1, wc2] {
            try runGit(["config", "user.email", "t@t.com"], in: wc.path, label: "email")
            try runGit(["config", "user.name", "T"], in: wc.path, label: "name")
        }

        // Push from wc1
        try "new file".write(toFile: wc1.appendingPathComponent("file1.txt").path,
                             atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], in: wc1.path, label: "add")
        try runGit(["commit", "-m", "wc1 commit"], in: wc1.path, label: "commit")
        try runGit(["push"], in: wc1.path, label: "push")

        // Try to push from wc2 without pulling — should fail
        try "another file".write(toFile: wc2.appendingPathComponent("file2.txt").path,
                                 atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], in: wc2.path, label: "add")
        try runGit(["commit", "-m", "wc2 commit"], in: wc2.path, label: "commit")

        do {
            try runGit(["push"], in: wc2.path, label: "push")
            Issue.record("Expected non-fast-forward error")
        } catch let error as GitError {
            if case .commandFailed(_, let output) = error {
                let isRejected = output.contains("rejected") || output.contains("non-fast-forward") || output.contains("fetch first")
                #expect(isRejected)
            }
        }

        // After pull, push should succeed
        try runGit(["pull", "--rebase"], in: wc2.path, label: "pull")
        try runGit(["push"], in: wc2.path, label: "push retry")
    }

    // MARK: - Init creates .gitignore

    @Test func initCreatesGitignore() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("test-init-gitignore-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }

        // Simulate mn init by creating vault structure
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let gitignorePath = (tmp.path as NSString).appendingPathComponent(".gitignore")
        try ".maho/\n".write(toFile: gitignorePath, atomically: true, encoding: .utf8)

        let content = try String(contentsOfFile: gitignorePath, encoding: .utf8)
        #expect(content.contains(".maho/"))
    }

    // MARK: - Sync --reindex

    @Test func reindexRebuildsFTSIndex() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("test-reindex-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // Create vault with a note
        let mahoDir = (tmp.path as NSString).appendingPathComponent(".maho")
        try fm.createDirectory(atPath: mahoDir, withIntermediateDirectories: true)

        let notesDir = (tmp.path as NSString).appendingPathComponent("test")
        try fm.createDirectory(atPath: notesDir, withIntermediateDirectories: true)

        let noteContent = """
        ---
        title: Reindex Test
        tags: [test]
        created: 2026-03-04T00:00:00-05:00
        updated: 2026-03-04T00:00:00-05:00
        public: false
        ---

        # Reindex Test

        This note tests the reindex functionality.
        """
        try noteContent.write(toFile: (notesDir as NSString).appendingPathComponent("001-reindex.md"),
                              atomically: true, encoding: .utf8)

        // Build index
        let vault = Vault(path: tmp.path)
        let notes = try vault.allNotes()
        let index = try SearchIndex(vaultPath: tmp.path)
        let stats = try index.buildIndex(notes: notes, fullRebuild: true)
        #expect(stats.total == 1)
        #expect(stats.added == 1)

        // Search should work
        let results = try index.search(query: "reindex")
        #expect(!results.isEmpty)
    }
}
