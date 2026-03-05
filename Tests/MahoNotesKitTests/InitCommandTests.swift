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

    // MARK: - Global config

    @Test func createsGlobalConfig() throws {
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
        #expect(content.contains("embed:"))
        #expect(content.contains("model: builtin"))
    }

    @Test func doesNotOverwriteExistingGlobalConfig() throws {
        let globalDir = try makeTempDir()
        let vaultDir = try makeTempDir()
        defer { cleanup(globalDir, vaultDir) }

        // Write a custom config first
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

    // MARK: - Author and github flags

    @Test func setsAuthorAndGithubInMahoYaml() throws {
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

    // MARK: - --no-tutorial

    @Test func noTutorialSkipsTutorialNotes() throws {
        let globalDir = try makeTempDir()
        let vaultDir = try makeTempDir()
        defer { cleanup(globalDir, vaultDir) }

        try initVault(
            vaultPath: vaultDir.path,
            authorName: "",
            githubRepo: "",
            skipTutorial: true,
            globalConfigDir: globalDir.path
        )

        let gsDir = vaultDir.appendingPathComponent("getting-started").path
        #expect(!FileManager.default.fileExists(atPath: gsDir))
    }

    @Test func noTutorialOmitsCollectionFromMahoYaml() throws {
        let globalDir = try makeTempDir()
        let vaultDir = try makeTempDir()
        defer { cleanup(globalDir, vaultDir) }

        try initVault(
            vaultPath: vaultDir.path,
            authorName: "",
            githubRepo: "",
            skipTutorial: true,
            globalConfigDir: globalDir.path
        )

        let mahoYaml = try String(
            contentsOfFile: vaultDir.appendingPathComponent("maho.yaml").path,
            encoding: .utf8
        )
        #expect(!mahoYaml.contains("getting-started"))
        #expect(mahoYaml.contains("collections: []"))
    }

    @Test func withTutorialIncludesCollectionInMahoYaml() throws {
        let globalDir = try makeTempDir()
        let vaultDir = try makeTempDir()
        defer { cleanup(globalDir, vaultDir) }

        // Pass a fake URL — clone will fail gracefully (no throw)
        try initVault(
            vaultPath: vaultDir.path,
            authorName: "",
            githubRepo: "",
            skipTutorial: false,
            globalConfigDir: globalDir.path,
            tutorialRepoURL: "/nonexistent/fake/tutorial/repo"
        )

        let mahoYaml = try String(
            contentsOfFile: vaultDir.appendingPathComponent("maho.yaml").path,
            encoding: .utf8
        )
        #expect(mahoYaml.contains("getting-started"))
        #expect(mahoYaml.contains("Getting Started"))
    }

    // MARK: - Idempotency

    @Test func idempotentOnSecondRun() throws {
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

        // Second run with different flags — existing files must NOT be overwritten
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

    @Test func idempotentGlobalConfigNotOverwritten() throws {
        let globalDir = try makeTempDir()
        let vaultDir = try makeTempDir()
        defer { cleanup(globalDir, vaultDir) }

        // First run creates global config
        try initVault(
            vaultPath: vaultDir.path,
            authorName: "",
            githubRepo: "",
            skipTutorial: false,
            globalConfigDir: globalDir.path,
            tutorialRepoURL: "/nonexistent/fake/tutorial/repo"
        )

        let configPath = globalDir.appendingPathComponent("config.yaml")
        let afterFirst = try String(contentsOfFile: configPath.path, encoding: .utf8)

        // Second run must not overwrite
        try initVault(
            vaultPath: vaultDir.path,
            authorName: "",
            githubRepo: "",
            skipTutorial: false,
            globalConfigDir: globalDir.path,
            tutorialRepoURL: "/nonexistent/fake/tutorial/repo"
        )

        let afterSecond = try String(contentsOfFile: configPath.path, encoding: .utf8)
        #expect(afterFirst == afterSecond)
    }

    // MARK: - Vault structure

    @Test func createsRequiredVaultFiles() throws {
        let globalDir = try makeTempDir()
        let vaultDir = try makeTempDir()
        defer { cleanup(globalDir, vaultDir) }

        try initVault(
            vaultPath: vaultDir.path,
            authorName: "",
            githubRepo: "",
            skipTutorial: true,
            globalConfigDir: globalDir.path
        )

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: vaultDir.appendingPathComponent("maho.yaml").path))
        #expect(fm.fileExists(atPath: vaultDir.appendingPathComponent(".maho").path))
        #expect(fm.fileExists(atPath: vaultDir.appendingPathComponent(".gitignore").path))

        let gitignore = try String(
            contentsOfFile: vaultDir.appendingPathComponent(".gitignore").path,
            encoding: .utf8
        )
        #expect(gitignore.contains(".maho/"))
    }
}
