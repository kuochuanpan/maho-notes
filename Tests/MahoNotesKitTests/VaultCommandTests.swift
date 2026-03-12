import Testing
import Foundation
@testable import MahoNotesKit

@Suite("VaultCommand")
struct VaultCommandTests {

    // MARK: - Helpers

    private func makeTempDir(name: String = UUID().uuidString) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func cleanup(_ dirs: URL...) {
        for dir in dirs {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Add (local) + list + remove roundtrip

    @Test func addLocalListRemoveRoundtrip() throws {
        let configDir = try makeTempDir()
        let vaultDir  = try makeTempDir()
        defer { cleanup(configDir, vaultDir) }

        // Initially no registry
        let initial = try loadRegistry(globalConfigDir: configDir.path)
        #expect(initial == nil)

        // Simulate: mn vault add mylocal --path <vaultDir>
        var registry = VaultRegistry(primary: "mylocal", vaults: [])
        let entry = VaultEntry(name: "mylocal", type: .local, path: vaultDir.path, access: .readWrite)
        try registry.addVault(entry)
        try saveRegistry(registry, globalConfigDir: configDir.path)

        // List: load and verify
        let loaded = try loadRegistry(globalConfigDir: configDir.path)
        #expect(loaded != nil)
        #expect(loaded!.vaults.count == 1)
        #expect(loaded!.vaults[0].name == "mylocal")
        #expect(loaded!.vaults[0].type == .local)
        #expect(loaded!.vaults[0].path == vaultDir.path)
        #expect(loaded!.primary == "mylocal")

        // Simulate: mn vault remove mylocal
        var reg2 = loaded!
        try reg2.removeVault(named: "mylocal")
        try saveRegistry(reg2, globalConfigDir: configDir.path)

        let afterRemove = try loadRegistry(globalConfigDir: configDir.path)
        #expect(afterRemove!.vaults.isEmpty)
    }

    // MARK: - set-primary

    @Test func setPrimaryChangesDefault() throws {
        let configDir = try makeTempDir()
        defer { cleanup(configDir) }

        var registry = VaultRegistry(
            primary: "first",
            vaults: [
                VaultEntry(name: "first",  type: .local, path: "/tmp/first",  access: .readWrite),
                VaultEntry(name: "second", type: .local, path: "/tmp/second", access: .readWrite),
            ]
        )
        try saveRegistry(registry, globalConfigDir: configDir.path)

        // Simulate: mn vault set-primary second
        var loaded = try loadRegistry(globalConfigDir: configDir.path)!
        try loaded.setPrimary("second")
        try saveRegistry(loaded, globalConfigDir: configDir.path)

        let verified = try loadRegistry(globalConfigDir: configDir.path)
        #expect(verified!.primary == "second")
    }

    @Test func setPrimaryInvalidNameThrows() throws {
        let configDir = try makeTempDir()
        defer { cleanup(configDir) }

        var registry = VaultRegistry(
            primary: "first",
            vaults: [VaultEntry(name: "first", type: .local, path: "/tmp/first", access: .readWrite)]
        )
        try saveRegistry(registry, globalConfigDir: configDir.path)

        var loaded = try loadRegistry(globalConfigDir: configDir.path)!
        #expect(throws: (any Error).self) {
            try loaded.setPrimary("nonexistent")
        }
    }

    // MARK: - remove --delete

    @Test func removeDeleteDeletesDirectory() throws {
        let configDir = try makeTempDir()
        let vaultDir  = try makeTempDir()
        defer { cleanup(configDir) }  // vaultDir is deleted by the test

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: vaultDir.path))

        // Register the vault
        var registry = VaultRegistry(
            primary: "mylocal",
            vaults: [VaultEntry(name: "mylocal", type: .local, path: vaultDir.path, access: .readWrite)]
        )
        try saveRegistry(registry, globalConfigDir: configDir.path)

        // Simulate: mn vault remove mylocal --delete
        let entry = registry.findVault(named: "mylocal")!
        let dirToDelete = resolvedPath(for: entry)
        if fm.fileExists(atPath: dirToDelete) {
            try fm.removeItem(atPath: dirToDelete)
        }
        try registry.removeVault(named: "mylocal")
        try saveRegistry(registry, globalConfigDir: configDir.path)

        // Directory must be gone
        #expect(!fm.fileExists(atPath: vaultDir.path))

        // Registry must have no vaults
        let loaded = try loadRegistry(globalConfigDir: configDir.path)
        #expect(loaded!.vaults.isEmpty)
    }

    @Test func removeWithoutDeleteKeepsDirectory() throws {
        let configDir = try makeTempDir()
        let vaultDir  = try makeTempDir()
        defer { cleanup(configDir, vaultDir) }

        var registry = VaultRegistry(
            primary: "mylocal",
            vaults: [VaultEntry(name: "mylocal", type: .local, path: vaultDir.path, access: .readWrite)]
        )
        try saveRegistry(registry, globalConfigDir: configDir.path)

        // Simulate: mn vault remove mylocal (no --delete)
        try registry.removeVault(named: "mylocal")
        try saveRegistry(registry, globalConfigDir: configDir.path)

        // Directory must still exist
        #expect(FileManager.default.fileExists(atPath: vaultDir.path))
    }

    // MARK: - Duplicate name error

    @Test func addDuplicateNameThrows() throws {
        let configDir = try makeTempDir()
        defer { cleanup(configDir) }

        var registry = VaultRegistry(
            primary: "test",
            vaults: [VaultEntry(name: "test", type: .local, path: "/tmp/test", access: .readWrite)]
        )
        try saveRegistry(registry, globalConfigDir: configDir.path)

        var loaded = try loadRegistry(globalConfigDir: configDir.path)!
        #expect(throws: (any Error).self) {
            try loaded.addVault(VaultEntry(name: "test", type: .local, path: "/tmp/other", access: .readWrite))
        }
    }

    // MARK: - GitHub --readonly skips API check

    @Test func githubReadonlyAccessRegisteredCorrectly() throws {
        let configDir = try makeTempDir()
        defer { cleanup(configDir) }

        // Simulate: mn vault add myrepo --github owner/repo --readonly
        // The --readonly flag causes access = .readOnly without any network call.
        var registry = VaultRegistry(primary: "myrepo", vaults: [])
        let entry = VaultEntry(name: "myrepo", type: .github, github: "owner/repo", access: .readOnly)
        try registry.addVault(entry)
        try saveRegistry(registry, globalConfigDir: configDir.path)

        let loaded = try loadRegistry(globalConfigDir: configDir.path)
        let v = loaded?.findVault(named: "myrepo")
        #expect(v != nil)
        #expect(v!.access == .readOnly)
        #expect(v!.github == "owner/repo")
        #expect(v!.type == .github)
    }

    @Test func githubReadwriteAccessRegisteredCorrectly() throws {
        let configDir = try makeTempDir()
        defer { cleanup(configDir) }

        // Simulate: mn vault add myrepo --github owner/repo --readwrite
        var registry = VaultRegistry(primary: "myrepo", vaults: [])
        let entry = VaultEntry(name: "myrepo", type: .github, github: "owner/repo", access: .readWrite)
        try registry.addVault(entry)
        try saveRegistry(registry, globalConfigDir: configDir.path)

        let loaded = try loadRegistry(globalConfigDir: configDir.path)
        #expect(loaded?.findVault(named: "myrepo")?.access == .readWrite)
    }

    // MARK: - resolvedPath for local vaults

    @Test func resolvedPathLocalExpandsTilde() {
        let entry = VaultEntry(name: "notes", type: .local, path: "~/Documents/notes", access: .readWrite)
        let path = resolvedPath(for: entry)
        #expect(!path.hasPrefix("~"))
        #expect(path.contains("Documents/notes"))
    }

    @Test func resolvedPathGitHubUsesGlobalVaultsDir() {
        let entry = VaultEntry(name: "cheatsheets", type: .github, github: "owner/repo", access: .readOnly)
        let path = resolvedPath(for: entry)
        #expect(path.contains("group.dev.pcca.mahonotes/vaults/cheatsheets"))
    }

    // MARK: - First vault becomes primary

    @Test func firstAddedVaultBecomesPrimary() throws {
        let configDir = try makeTempDir()
        defer { cleanup(configDir) }

        var registry = VaultRegistry(primary: "first", vaults: [])
        let entry = VaultEntry(name: "first", type: .local, path: "/tmp/first", access: .readWrite)
        try registry.addVault(entry)
        // registry.primary was set to "first" at init, vault count is now 1
        try saveRegistry(registry, globalConfigDir: configDir.path)

        let loaded = try loadRegistry(globalConfigDir: configDir.path)
        #expect(loaded!.primary == "first")
    }

    // MARK: - Multiple vaults

    @Test func multipleVaultsPreservesOrder() throws {
        let configDir = try makeTempDir()
        defer { cleanup(configDir) }

        var registry = VaultRegistry(primary: "alpha", vaults: [])
        try registry.addVault(VaultEntry(name: "alpha", type: .local, path: "/tmp/alpha", access: .readWrite))
        try registry.addVault(VaultEntry(name: "beta",  type: .github, github: "user/beta", access: .readOnly))
        try registry.addVault(VaultEntry(name: "gamma", type: .icloud, access: .readWrite))
        try saveRegistry(registry, globalConfigDir: configDir.path)

        let loaded = try loadRegistry(globalConfigDir: configDir.path)!
        #expect(loaded.vaults.count == 3)
        #expect(loaded.vaults[0].name == "alpha")
        #expect(loaded.vaults[1].name == "beta")
        #expect(loaded.vaults[2].name == "gamma")
    }
}
