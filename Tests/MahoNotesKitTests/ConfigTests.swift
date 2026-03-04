import Testing
import Foundation
@testable import MahoNotesKit

@Suite("Config Validation")
struct ConfigTests {
    private func makeTestVault() throws -> (Config, URL) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("test-vault-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        // Create a proper maho.yaml
        let yaml = """
        author:
          name: Test User
          url: https://example.com
        github:
          repo: test/repo
        site:
          domain: example.com
          title: Test Notes
          theme: default
        """
        try yaml.write(to: tmp.appendingPathComponent("maho.yaml"), atomically: true, encoding: .utf8)

        return (Config(vaultPath: tmp.path), tmp)
    }

    // MARK: - Section key blocking

    @Test func setSectionKeyAuthorThrows() throws {
        let (config, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(throws: (any Error).self) {
            try config.setValue(key: "author", value: "maho")
        }
    }

    @Test func setSectionKeyGithubThrows() throws {
        let (config, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(throws: (any Error).self) {
            try config.setValue(key: "github", value: "foo")
        }
    }

    @Test func setSectionKeySiteThrows() throws {
        let (config, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(throws: (any Error).self) {
            try config.setValue(key: "site", value: "bar")
        }
    }

    // MARK: - Unknown key blocking

    @Test func setUnknownKeyThrows() throws {
        let (config, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(throws: (any Error).self) {
            try config.setValue(key: "blah", value: "xyz")
        }
    }

    @Test func setUnknownNestedKeyThrows() throws {
        let (config, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(throws: (any Error).self) {
            try config.setValue(key: "author.nickname", value: "foo")
        }
    }

    // MARK: - Valid keys work

    @Test func setAuthorNameSucceeds() throws {
        let (config, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try config.setValue(key: "author.name", value: "New Name")
        let loaded = try config.loadVaultConfig()
        let author = loaded["author"] as? [String: Any]
        #expect(author?["name"] as? String == "New Name")
    }

    @Test func setAuthorUrlSucceeds() throws {
        let (config, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try config.setValue(key: "author.url", value: "https://new.dev")
        let loaded = try config.loadVaultConfig()
        let author = loaded["author"] as? [String: Any]
        #expect(author?["url"] as? String == "https://new.dev")
    }

    @Test func setSiteTitleSucceeds() throws {
        let (config, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try config.setValue(key: "site.title", value: "My New Title")
        let loaded = try config.loadVaultConfig()
        let site = loaded["site"] as? [String: Any]
        #expect(site?["title"] as? String == "My New Title")
    }

    @Test func setGithubRepoSucceeds() throws {
        let (config, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try config.setValue(key: "github.repo", value: "user/new-repo")
        let loaded = try config.loadVaultConfig()
        let github = loaded["github"] as? [String: Any]
        #expect(github?["repo"] as? String == "user/new-repo")
    }

    // MARK: - Section overwrite regression

    @Test func sectionNotOverwrittenByStringValue() throws {
        let (config, tmp) = try makeTestVault()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Attempt to overwrite author section — should throw
        #expect(throws: (any Error).self) {
            try config.setValue(key: "author", value: "just-a-string")
        }

        // Verify original nested structure is preserved
        let loaded = try config.loadVaultConfig()
        let author = loaded["author"] as? [String: Any]
        #expect(author != nil, "author should still be a dictionary")
        #expect(author?["name"] as? String == "Test User")
        #expect(author?["url"] as? String == "https://example.com")
    }
}
