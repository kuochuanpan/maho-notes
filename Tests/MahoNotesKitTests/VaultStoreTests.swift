import Testing
import Foundation
import Yams
@testable import MahoNotesKit

@Suite("VaultStore")
struct VaultStoreTests {

    // MARK: - Helpers

    private func makeTempDir() throws -> String {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp.path
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - VaultConfig Tests

    @Test("VaultConfig roundtrip encode/decode")
    func vaultConfigRoundtrip() throws {
        let config = VaultConfig(
            author: .init(name: "Test Author", url: "https://example.com"),
            collections: [
                .init(id: "notes", name: "My Notes", icon: "folder", description: "Main collection"),
                .init(id: "research", name: "Research", icon: "flask"),
            ],
            github: .init(repo: "user/vault"),
            site: .init(domain: "notes.example.com", title: "My Site", theme: "default")
        )

        let encoder = YAMLEncoder()
        let yaml = try encoder.encode(config)
        let decoded = try YAMLDecoder().decode(VaultConfig.self, from: yaml)

        #expect(decoded == config)
        #expect(decoded.author?.name == "Test Author")
        #expect(decoded.collections?.count == 2)
        #expect(decoded.github?.repo == "user/vault")
        #expect(decoded.site?.theme == "default")
    }

    @Test("VaultConfig decodes from minimal YAML")
    func vaultConfigMinimal() throws {
        let yaml = """
        author:
          name: "Jane"
        collections: []
        """
        let config = try YAMLDecoder().decode(VaultConfig.self, from: yaml)
        #expect(config.author?.name == "Jane")
        #expect(config.collections?.isEmpty == true)
        #expect(config.github == nil)
        #expect(config.site == nil)
    }

    @Test("VaultConfig decodes with missing optional fields")
    func vaultConfigMissingOptionals() throws {
        let yaml = "{}"
        let config = try YAMLDecoder().decode(VaultConfig.self, from: yaml)
        #expect(config.author == nil)
        #expect(config.collections == nil)
    }

    // MARK: - DeviceConfig Tests

    @Test("DeviceConfig CodingKeys maps github_token correctly")
    func deviceConfigCodingKeys() throws {
        let yaml = """
        auth:
          github_token: "ghp_test123"
        embed:
          model: "minilm"
        """
        let config = try YAMLDecoder().decode(DeviceConfig.self, from: yaml)
        #expect(config.auth?.githubToken == "ghp_test123")
        #expect(config.embed?.model == "minilm")

        // Roundtrip should preserve the snake_case key
        let encoder = YAMLEncoder()
        let encoded = try encoder.encode(config)
        #expect(encoded.contains("github_token"))
    }

    // MARK: - GlobalConfig Tests

    @Test("GlobalConfig roundtrip with CloudSyncMode")
    func globalConfigRoundtrip() throws {
        let config = GlobalConfig(
            auth: .init(githubToken: "ghp_abc"),
            embed: .init(model: "e5-large"),
            sync: .init(cloud: .icloud)
        )

        let encoder = YAMLEncoder()
        let yaml = try encoder.encode(config)
        let decoded = try YAMLDecoder().decode(GlobalConfig.self, from: yaml)

        #expect(decoded == config)
        #expect(decoded.sync?.cloud == .icloud)
    }

    @Test("GlobalConfig defaults sync to nil")
    func globalConfigDefaultSync() throws {
        let yaml = """
        auth: {}
        embed:
          model: builtin
        """
        let config = try YAMLDecoder().decode(GlobalConfig.self, from: yaml)
        #expect(config.sync == nil)
    }

    // MARK: - VaultStore Registry Tests

    @Test("VaultStore loads and saves registry")
    func storeRegistryRoundtrip() async throws {
        let tmpDir = try makeTempDir()
        defer { cleanup(tmpDir) }

        let store = VaultStore(globalConfigDir: tmpDir)
        let registry = VaultRegistry(
            primary: "test",
            vaults: [VaultEntry(name: "test", type: .device, access: .readWrite)]
        )

        try await store.saveRegistry(registry)
        let loaded = try await store.loadRegistry()

        #expect(loaded != nil)
        #expect(loaded?.primary == "test")
        #expect(loaded?.vaults.count == 1)
    }

    @Test("VaultStore returns nil for empty directory")
    func storeEmptyRegistry() async throws {
        let tmpDir = try makeTempDir()
        defer { cleanup(tmpDir) }

        let store = VaultStore(globalConfigDir: tmpDir)
        let result = try await store.loadRegistry()
        #expect(result == nil)
    }

    // MARK: - VaultStore Register/Unregister Tests

    @Test("VaultStore registerVault — device type ignores path")
    func registerDeviceVault() async throws {
        let tmpDir = try makeTempDir()
        defer { cleanup(tmpDir) }

        let store = VaultStore(globalConfigDir: tmpDir)
        let entry = VaultEntry(name: "my-vault", type: .device, path: "/should/be/ignored", access: .readWrite)
        try await store.registerVault(entry)

        let registry = try await store.loadRegistry()
        let registered = registry?.findVault(named: "my-vault")
        #expect(registered != nil)
        #expect(registered?.path == nil)
        #expect(registered?.type == .device)
    }

    @Test("VaultStore registerVault — local type requires path")
    func registerLocalVaultRequiresPath() async throws {
        let tmpDir = try makeTempDir()
        defer { cleanup(tmpDir) }

        let store = VaultStore(globalConfigDir: tmpDir)
        let entry = VaultEntry(name: "bad", type: .local, path: nil, access: .readWrite)

        do {
            try await store.registerVault(entry)
            Issue.record("Should have thrown VaultStoreError.localRequiresPath")
        } catch is VaultStoreError {
            // expected
        }
    }

    @Test("VaultStore registerVault — local type validates path exists")
    func registerLocalVaultPathMustExist() async throws {
        let tmpDir = try makeTempDir()
        defer { cleanup(tmpDir) }

        let store = VaultStore(globalConfigDir: tmpDir)
        let entry = VaultEntry(name: "bad", type: .local, path: "/nonexistent/path/xyz", access: .readWrite)

        do {
            try await store.registerVault(entry)
            Issue.record("Should have thrown VaultStoreError.pathDoesNotExist")
        } catch is VaultStoreError {
            // expected
        }
    }

    @Test("VaultStore registerVault — local type with valid path succeeds")
    func registerLocalVaultSuccess() async throws {
        let tmpDir = try makeTempDir()
        defer { cleanup(tmpDir) }

        let localDir = (tmpDir as NSString).appendingPathComponent("my-local-vault")
        try FileManager.default.createDirectory(atPath: localDir, withIntermediateDirectories: true)

        let store = VaultStore(globalConfigDir: tmpDir)
        let entry = VaultEntry(name: "local-v", type: .local, path: localDir, access: .readWrite)
        try await store.registerVault(entry)

        let registry = try await store.loadRegistry()
        let registered = registry?.findVault(named: "local-v")
        #expect(registered != nil)
        #expect(registered?.type == .local)
        #expect(registered?.path == localDir)
    }

    @Test("VaultStore registerVault — first vault becomes primary")
    func registerFirstVaultIsPrimary() async throws {
        let tmpDir = try makeTempDir()
        defer { cleanup(tmpDir) }

        let store = VaultStore(globalConfigDir: tmpDir)
        let entry = VaultEntry(name: "first", type: .device, access: .readWrite)
        try await store.registerVault(entry)

        let registry = try await store.loadRegistry()
        #expect(registry?.primary == "first")
    }

    @Test("VaultStore registerVault — duplicate name throws")
    func registerDuplicateThrows() async throws {
        let tmpDir = try makeTempDir()
        defer { cleanup(tmpDir) }

        let store = VaultStore(globalConfigDir: tmpDir)
        let entry = VaultEntry(name: "dup", type: .device, access: .readWrite)
        try await store.registerVault(entry)

        do {
            try await store.registerVault(entry)
            Issue.record("Should have thrown VaultRegistryError.duplicateName")
        } catch {
            // expected
        }
    }

    @Test("VaultStore unregisterVault removes entry")
    func unregisterVault() async throws {
        let tmpDir = try makeTempDir()
        defer { cleanup(tmpDir) }

        let store = VaultStore(globalConfigDir: tmpDir)
        try await store.registerVault(VaultEntry(name: "a", type: .device, access: .readWrite))
        try await store.registerVault(VaultEntry(name: "b", type: .device, access: .readWrite))

        try await store.unregisterVault(named: "a")
        let registry = try await store.loadRegistry()
        #expect(registry?.findVault(named: "a") == nil)
        #expect(registry?.findVault(named: "b") != nil)
    }

    // MARK: - VaultStore Cached Registry Tests

    @Test("VaultStore loadCachedRegistry reads vaults-cache.yaml")
    func cachedRegistryFallback() async throws {
        let tmpDir = try makeTempDir()
        defer { cleanup(tmpDir) }

        // Write a cache file manually
        let registry = VaultRegistry(
            primary: "cached",
            vaults: [VaultEntry(name: "cached", type: .device, access: .readWrite)]
        )
        let yaml = try YAMLEncoder().encode(registry)
        let cachePath = (tmpDir as NSString).appendingPathComponent("vaults-cache.yaml")
        try yaml.write(toFile: cachePath, atomically: true, encoding: .utf8)

        let store = VaultStore(globalConfigDir: tmpDir)
        let loaded = try await store.loadCachedRegistry()
        #expect(loaded?.primary == "cached")
    }

    @Test("VaultStore loadCachedRegistry returns nil when no cache")
    func cachedRegistryNil() async throws {
        let tmpDir = try makeTempDir()
        defer { cleanup(tmpDir) }

        let store = VaultStore(globalConfigDir: tmpDir)
        let loaded = try await store.loadCachedRegistry()
        #expect(loaded == nil)
    }

    // MARK: - VaultStore VaultConfig I/O Tests

    @Test("VaultStore load/save VaultConfig")
    func vaultConfigIO() async throws {
        let tmpDir = try makeTempDir()
        defer { cleanup(tmpDir) }

        let vaultDir = (tmpDir as NSString).appendingPathComponent("test-vault")
        try FileManager.default.createDirectory(atPath: vaultDir, withIntermediateDirectories: true)

        let store = VaultStore(globalConfigDir: tmpDir)
        let config = VaultConfig(
            author: .init(name: "Maho"),
            collections: [.init(id: "notes", name: "Notes")],
            github: .init(repo: "user/vault")
        )

        try await store.saveVaultConfig(config, at: vaultDir)
        let loaded = try await store.loadVaultConfig(at: vaultDir)

        #expect(loaded.author?.name == "Maho")
        #expect(loaded.collections?.first?.id == "notes")
        #expect(loaded.github?.repo == "user/vault")
    }

    @Test("VaultStore loadVaultConfig returns empty for missing file")
    func vaultConfigMissing() async throws {
        let tmpDir = try makeTempDir()
        defer { cleanup(tmpDir) }

        let store = VaultStore(globalConfigDir: tmpDir)
        let config = try await store.loadVaultConfig(at: tmpDir)
        #expect(config.author == nil)
        #expect(config.collections == nil)
    }

    // MARK: - VaultStore DeviceConfig I/O Tests

    @Test("VaultStore load/save DeviceConfig")
    func deviceConfigIO() async throws {
        let tmpDir = try makeTempDir()
        defer { cleanup(tmpDir) }

        let vaultDir = (tmpDir as NSString).appendingPathComponent("test-vault")
        try FileManager.default.createDirectory(atPath: vaultDir, withIntermediateDirectories: true)

        let store = VaultStore(globalConfigDir: tmpDir)
        let config = DeviceConfig(
            embed: .init(model: "e5-small"),
            auth: .init(githubToken: "ghp_secret")
        )

        try await store.saveDeviceConfig(config, at: vaultDir)
        let loaded = try await store.loadDeviceConfig(at: vaultDir)

        #expect(loaded.embed?.model == "e5-small")
        #expect(loaded.auth?.githubToken == "ghp_secret")
    }

    @Test("VaultStore saveDeviceConfig creates .maho/ directory")
    func deviceConfigCreatesDir() async throws {
        let tmpDir = try makeTempDir()
        defer { cleanup(tmpDir) }

        let vaultDir = (tmpDir as NSString).appendingPathComponent("new-vault")
        try FileManager.default.createDirectory(atPath: vaultDir, withIntermediateDirectories: true)

        let store = VaultStore(globalConfigDir: tmpDir)
        try await store.saveDeviceConfig(DeviceConfig(embed: .init(model: "minilm")), at: vaultDir)

        let mahoDir = (vaultDir as NSString).appendingPathComponent(".maho")
        #expect(FileManager.default.fileExists(atPath: mahoDir))
    }

    // MARK: - VaultStore GlobalConfig I/O Tests

    @Test("VaultStore load/save GlobalConfig")
    func globalConfigIO() async throws {
        let tmpDir = try makeTempDir()
        defer { cleanup(tmpDir) }

        let store = VaultStore(globalConfigDir: tmpDir)
        let config = GlobalConfig(
            auth: .init(githubToken: "ghp_global"),
            embed: .init(model: "minilm"),
            sync: .init(cloud: .off)
        )

        try await store.saveGlobalConfig(config)
        let loaded = try await store.loadGlobalConfig()

        #expect(loaded == config)
        #expect(loaded.sync?.cloud == .off)
        #expect(loaded.auth?.githubToken == "ghp_global")
    }

    @Test("VaultStore loadGlobalConfig returns defaults for missing file")
    func globalConfigDefaults() async throws {
        let tmpDir = try makeTempDir()
        defer { cleanup(tmpDir) }

        let store = VaultStore(globalConfigDir: tmpDir)
        let config = try await store.loadGlobalConfig()
        #expect(config.auth == nil)
        #expect(config.sync == nil)
    }

    // MARK: - VaultStore Cloud Sync Mode Tests

    @Test("VaultStore cloudSyncMode defaults to off")
    func cloudSyncModeDefault() async throws {
        let tmpDir = try makeTempDir()
        defer { cleanup(tmpDir) }

        let store = VaultStore(globalConfigDir: tmpDir)
        let mode = await store.cloudSyncMode()
        #expect(mode == .off)
    }

    @Test("VaultStore set/get cloudSyncMode")
    func cloudSyncModeSetGet() async throws {
        let tmpDir = try makeTempDir()
        defer { cleanup(tmpDir) }

        let store = VaultStore(globalConfigDir: tmpDir)
        try await store.setCloudSyncMode(.icloud)
        let mode = await store.cloudSyncMode()
        #expect(mode == .icloud)
    }

    // MARK: - VaultStore cleanupCloudArtifacts Tests

    @Test("VaultStore cleanupCloudArtifacts removes cache file")
    func cleanupRemovesCache() async throws {
        let tmpDir = try makeTempDir()
        defer { cleanup(tmpDir) }

        // Create a cache file
        let cachePath = (tmpDir as NSString).appendingPathComponent("vaults-cache.yaml")
        try "test".write(toFile: cachePath, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: cachePath))

        let store = VaultStore(globalConfigDir: tmpDir)
        try await store.cleanupCloudArtifacts()

        #expect(!FileManager.default.fileExists(atPath: cachePath))
    }

    // MARK: - Path Resolution Tests

    @Test("VaultStore resolvedPath delegates correctly")
    func resolvedPathDelegates() async throws {
        let tmpDir = try makeTempDir()
        defer { cleanup(tmpDir) }

        let store = VaultStore(globalConfigDir: tmpDir)
        let entry = VaultEntry(name: "test-vault", type: .device, access: .readWrite)
        let path = await store.resolvedPath(for: entry)
        #expect(path.contains("group.dev.pcca.mahonotes/vaults/test-vault/"))
    }

    @Test("VaultStore resolvedPath — github type")
    func resolvedPathGitHub() async throws {
        let tmpDir = try makeTempDir()
        defer { cleanup(tmpDir) }

        let store = VaultStore(globalConfigDir: tmpDir)
        let entry = VaultEntry(name: "my-repo", type: .github, github: "user/repo", access: .readOnly)
        let path = await store.resolvedPath(for: entry)
        #expect(path.contains("group.dev.pcca.mahonotes/vaults/my-repo/"))
    }
}
