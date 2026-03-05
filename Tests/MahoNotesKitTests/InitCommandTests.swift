import Testing
import Foundation
@testable import MahoNotesKit

@Suite("VaultInit")
struct InitCommandTests {
    private func makeTempDir(name: String = UUID().uuidString) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func cleanup(_ urls: URL...) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - resolveVaultRoot

    @Test func resolveVaultRootLocal() {
        let path = resolveVaultRoot(storage: .local)
        #expect(path.hasSuffix("/.maho/vaults"))
    }

    @Test func resolveVaultRootICloud() {
        let path = resolveVaultRoot(storage: .icloud)
        #expect(path.contains("iCloud~com.pcca.mahonotes"))
        #expect(path.hasSuffix("/vaults"))
    }

    @Test func resolveVaultRootNilFallsBackToLocal() {
        // In CI / test environment iCloud container doesn't exist -> local
        if !iCloudContainerExists() {
            let path = resolveVaultRoot(storage: nil)
            #expect(path.hasSuffix("/.maho/vaults"))
        }
    }

    // MARK: - createEmptyVault: global config

    @Test func createEmptyVaultCreatesGlobalConfig() throws {
        let globalDir = try makeTempDir()
        let vaultRoot = try makeTempDir()
        defer { cleanup(globalDir, vaultRoot) }

        try createEmptyVault(
            name: "test",
            vaultRoot: vaultRoot.path,
            authorName: "",
            skipTutorial: true,
            globalConfigDir: globalDir.path
        )

        let configPath = globalDir.appendingPathComponent("config.yaml").path
        #expect(FileManager.default.fileExists(atPath: configPath))
        let content = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(content.contains("auth:"))
        #expect(content.contains("embed:"))
        #expect(content.contains("model: builtin"))
    }

    @Test func createEmptyVaultDoesNotOverwriteExistingGlobalConfig() throws {
        let globalDir = try makeTempDir()
        let vaultRoot = try makeTempDir()
        defer { cleanup(globalDir, vaultRoot) }

        let configPath = globalDir.appendingPathComponent("config.yaml")
        let original = "# my custom config\nauth:\n  github_token: abc123\n"
        try original.write(to: configPath, atomically: true, encoding: .utf8)

        try createEmptyVault(
            name: "test",
            vaultRoot: vaultRoot.path,
            authorName: "",
            skipTutorial: true,
            globalConfigDir: globalDir.path
        )

        let after = try String(contentsOfFile: configPath.path, encoding: .utf8)
        #expect(after == original)
    }

    // MARK: - createEmptyVault: vault files

    @Test func createEmptyVaultCreatesRequiredFiles() throws {
        let globalDir = try makeTempDir()
        let vaultRoot = try makeTempDir()
        defer { cleanup(globalDir, vaultRoot) }

        try createEmptyVault(
            name: "personal",
            vaultRoot: vaultRoot.path,
            authorName: "",
            skipTutorial: true,
            globalConfigDir: globalDir.path
        )

        let vaultPath = vaultRoot.appendingPathComponent("personal")
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: vaultPath.appendingPathComponent("maho.yaml").path))
        #expect(fm.fileExists(atPath: vaultPath.appendingPathComponent(".maho").path))
        #expect(fm.fileExists(atPath: vaultPath.appendingPathComponent(".gitignore").path))

        let gitignore = try String(
            contentsOfFile: vaultPath.appendingPathComponent(".gitignore").path,
            encoding: .utf8
        )
        #expect(gitignore.contains(".maho/"))
    }

    @Test func createEmptyVaultSetsAuthorInMahoYaml() throws {
        let globalDir = try makeTempDir()
        let vaultRoot = try makeTempDir()
        defer { cleanup(globalDir, vaultRoot) }

        try createEmptyVault(
            name: "personal",
            vaultRoot: vaultRoot.path,
            authorName: "Test User",
            skipTutorial: true,
            globalConfigDir: globalDir.path
        )

        let mahoYaml = try String(
            contentsOfFile: vaultRoot.appendingPathComponent("personal/maho.yaml").path,
            encoding: .utf8
        )
        #expect(mahoYaml.contains("name: \"Test User\""))
    }

    @Test func createEmptyVaultSkipsTutorialWhenFlagSet() throws {
        let globalDir = try makeTempDir()
        let vaultRoot = try makeTempDir()
        defer { cleanup(globalDir, vaultRoot) }

        try createEmptyVault(
            name: "personal",
            vaultRoot: vaultRoot.path,
            authorName: "",
            skipTutorial: true,
            globalConfigDir: globalDir.path
        )

        let vaultPath = vaultRoot.appendingPathComponent("personal")
        #expect(!FileManager.default.fileExists(atPath: vaultPath.appendingPathComponent("getting-started").path))
        let mahoYaml = try String(
            contentsOfFile: vaultPath.appendingPathComponent("maho.yaml").path,
            encoding: .utf8
        )
        #expect(!mahoYaml.contains("getting-started"))
        #expect(mahoYaml.contains("collections: []"))
    }

    @Test func createEmptyVaultIncludesTutorialInMahoYaml() throws {
        let globalDir = try makeTempDir()
        let vaultRoot = try makeTempDir()
        defer { cleanup(globalDir, vaultRoot) }

        try createEmptyVault(
            name: "personal",
            vaultRoot: vaultRoot.path,
            authorName: "",
            skipTutorial: false,
            globalConfigDir: globalDir.path,
            tutorialRepoURL: "/nonexistent/fake/tutorial/repo"
        )

        let mahoYaml = try String(
            contentsOfFile: vaultRoot.appendingPathComponent("personal/maho.yaml").path,
            encoding: .utf8
        )
        #expect(mahoYaml.contains("getting-started"))
        #expect(mahoYaml.contains("Getting Started"))
    }

    // MARK: - createEmptyVault: registry

    @Test func createEmptyVaultRegistersInRegistry() throws {
        let globalDir = try makeTempDir()
        let vaultRoot = try makeTempDir()
        defer { cleanup(globalDir, vaultRoot) }

        try createEmptyVault(
            name: "personal",
            vaultRoot: vaultRoot.path,
            authorName: "",
            skipTutorial: true,
            globalConfigDir: globalDir.path
        )

        let registry = try loadRegistry(globalConfigDir: globalDir.path)
        #expect(registry != nil)
        #expect(registry?.findVault(named: "personal") != nil)
        #expect(registry?.primary == "personal")
    }

    @Test func createEmptyVaultSetsFirstVaultAsPrimary() throws {
        let globalDir = try makeTempDir()
        let vaultRoot = try makeTempDir()
        defer { cleanup(globalDir, vaultRoot) }

        try createEmptyVault(
            name: "vault1",
            vaultRoot: vaultRoot.path,
            authorName: "",
            skipTutorial: true,
            globalConfigDir: globalDir.path
        )
        try createEmptyVault(
            name: "vault2",
            vaultRoot: vaultRoot.path,
            authorName: "",
            skipTutorial: true,
            globalConfigDir: globalDir.path
        )

        let registry = try loadRegistry(globalConfigDir: globalDir.path)
        // First vault stays primary
        #expect(registry?.primary == "vault1")
        #expect(registry?.findVault(named: "vault2") != nil)
    }

    // MARK: - createEmptyVault: idempotency

    @Test func createEmptyVaultIsIdempotent() throws {
        let globalDir = try makeTempDir()
        let vaultRoot = try makeTempDir()
        defer { cleanup(globalDir, vaultRoot) }

        try createEmptyVault(
            name: "personal",
            vaultRoot: vaultRoot.path,
            authorName: "First",
            skipTutorial: true,
            globalConfigDir: globalDir.path
        )

        let mahoYamlPath = vaultRoot.appendingPathComponent("personal/maho.yaml")
        let afterFirst = try String(contentsOfFile: mahoYamlPath.path, encoding: .utf8)

        // Second run with different author — existing files must NOT be overwritten
        try createEmptyVault(
            name: "personal",
            vaultRoot: vaultRoot.path,
            authorName: "Second",
            skipTutorial: false,
            globalConfigDir: globalDir.path
        )

        let afterSecond = try String(contentsOfFile: mahoYamlPath.path, encoding: .utf8)
        #expect(afterFirst == afterSecond)
        #expect(afterSecond.contains("name: \"First\""))
    }

    // MARK: - cloneGitHubVault

    @Test func cloneGitHubVaultThrowsOnBadRepo() throws {
        let globalDir = try makeTempDir()
        let vaultRoot = try makeTempDir()
        defer { cleanup(globalDir, vaultRoot) }

        var threw = false
        do {
            try cloneGitHubVault(
                repo: "nonexistent-user-xyz/bad-repo-xyz-12345",
                vaultRoot: vaultRoot.path,
                name: nil,
                globalConfigDir: globalDir.path
            )
        } catch is VaultInitError {
            threw = true
        }
        #expect(threw)
    }

    @Test func cloneGitHubVaultRegistersExistingDirectory() throws {
        let globalDir = try makeTempDir()
        let vaultRoot = try makeTempDir()
        defer { cleanup(globalDir, vaultRoot) }

        // Pre-create the directory with a maho.yaml (simulates already-cloned repo)
        let vaultPath = vaultRoot.appendingPathComponent("my-vault")
        try FileManager.default.createDirectory(at: vaultPath, withIntermediateDirectories: true)
        let mahoYaml = vaultPath.appendingPathComponent("maho.yaml")
        try "author:\n  name: \"\"\ngithub:\n  repo: \"user/my-vault\"\n".write(
            to: mahoYaml, atomically: true, encoding: .utf8
        )

        try cloneGitHubVault(
            repo: "user/my-vault",
            vaultRoot: vaultRoot.path,
            name: "my-vault",
            globalConfigDir: globalDir.path
        )

        let registry = try loadRegistry(globalConfigDir: globalDir.path)
        #expect(registry?.findVault(named: "my-vault") != nil)
        #expect(registry?.primary == "my-vault")
    }

    @Test func cloneGitHubVaultGeneratesMahoYamlIfMissing() throws {
        let globalDir = try makeTempDir()
        let vaultRoot = try makeTempDir()
        defer { cleanup(globalDir, vaultRoot) }

        // Pre-create directory WITHOUT maho.yaml (import mode)
        let vaultPath = vaultRoot.appendingPathComponent("bare-vault")
        try FileManager.default.createDirectory(at: vaultPath, withIntermediateDirectories: true)

        try cloneGitHubVault(
            repo: "user/bare-vault",
            vaultRoot: vaultRoot.path,
            name: "bare-vault",
            globalConfigDir: globalDir.path
        )

        let mahoYaml = try String(
            contentsOfFile: vaultPath.appendingPathComponent("maho.yaml").path,
            encoding: .utf8
        )
        #expect(mahoYaml.contains("repo: \"user/bare-vault\""))
    }

    // MARK: - Legacy initVault (backward compat)

    @Test func legacyInitVaultCreatesGlobalConfig() throws {
        let globalDir = try makeTempDir()
        let vaultDir = try makeTempDir()
        defer { cleanup(globalDir, vaultDir) }

        try initVault(
            vaultPath: vaultDir.path,
            authorName: "",
            githubRepo: "",
            skipTutorial: false,
            globalConfigDir: globalDir.path,
            tutorialRepoURL: "/nonexistent/fake/tutorial/repo"
        )

        let configPath = globalDir.appendingPathComponent("config.yaml").path
        #expect(FileManager.default.fileExists(atPath: configPath))
        let content = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(content.contains("auth:"))
        #expect(content.contains("model: builtin"))
    }

    @Test func legacyInitVaultDoesNotOverwriteExistingGlobalConfig() throws {
        let globalDir = try makeTempDir()
        let vaultDir = try makeTempDir()
        defer { cleanup(globalDir, vaultDir) }

        let configPath = globalDir.appendingPathComponent("config.yaml")
        let original = "# my custom config\nauth:\n  github_token: abc123\n"
        try original.write(to: configPath, atomically: true, encoding: .utf8)

        try initVault(
            vaultPath: vaultDir.path,
            authorName: "",
            githubRepo: "",
            skipTutorial: false,
            globalConfigDir: globalDir.path,
            tutorialRepoURL: "/nonexistent/fake/tutorial/repo"
        )

        let after = try String(contentsOfFile: configPath.path, encoding: .utf8)
        #expect(after == original)
    }

    @Test func legacyInitVaultSetsAuthorAndGithub() throws {
        let globalDir = try makeTempDir()
        let vaultDir = try makeTempDir()
        defer { cleanup(globalDir, vaultDir) }

        try initVault(
            vaultPath: vaultDir.path,
            authorName: "Test User",
            githubRepo: "user/repo",
            skipTutorial: false,
            globalConfigDir: globalDir.path,
            tutorialRepoURL: "/nonexistent/fake/tutorial/repo"
        )

        let mahoYaml = try String(
            contentsOfFile: vaultDir.appendingPathComponent("maho.yaml").path,
            encoding: .utf8
        )
        #expect(mahoYaml.contains("name: \"Test User\""))
        #expect(mahoYaml.contains("repo: \"user/repo\""))
    }

    @Test func legacyInitVaultIsIdempotent() throws {
        let globalDir = try makeTempDir()
        let vaultDir = try makeTempDir()
        defer { cleanup(globalDir, vaultDir) }

        try initVault(
            vaultPath: vaultDir.path,
            authorName: "First",
            githubRepo: "a/b",
            skipTutorial: false,
            globalConfigDir: globalDir.path,
            tutorialRepoURL: "/nonexistent/fake/tutorial/repo"
        )

        let mahoYamlPath = vaultDir.appendingPathComponent("maho.yaml")
        let afterFirst = try String(contentsOfFile: mahoYamlPath.path, encoding: .utf8)

        try initVault(
            vaultPath: vaultDir.path,
            authorName: "Second",
            githubRepo: "c/d",
            skipTutorial: true,
            globalConfigDir: globalDir.path
        )

        let afterSecond = try String(contentsOfFile: mahoYamlPath.path, encoding: .utf8)
        #expect(afterFirst == afterSecond)
        #expect(afterSecond.contains("name: \"First\""))
    }
}
