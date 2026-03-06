import Testing
import Foundation
@testable import MahoNotesKit

@Suite("VaultRegistry")
struct VaultRegistryTests {

    // MARK: - Helpers

    private func makeTempDir() throws -> String {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp.path
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func sampleRegistry() -> VaultRegistry {
        VaultRegistry(
            primary: "personal",
            vaults: [
                VaultEntry(name: "personal", type: .icloud, github: "user/maho-vault", access: .readWrite),
                VaultEntry(name: "cheatsheets", type: .github, github: "detailyang/awesome-cheatsheet", access: .readOnly),
                VaultEntry(name: "local-notes", type: .local, path: "~/Documents/my-notes", access: .readWrite),
            ]
        )
    }

    // MARK: - Load/save roundtrip

    @Test func roundtrip() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let original = sampleRegistry()
        try saveRegistry(original, globalConfigDir: dir)

        let loaded = try loadRegistry(globalConfigDir: dir)
        #expect(loaded != nil)
        #expect(loaded!.primary == original.primary)
        #expect(loaded!.vaults.count == original.vaults.count)
        #expect(loaded!.vaults[0].name == "personal")
        #expect(loaded!.vaults[0].type == .icloud)
        #expect(loaded!.vaults[0].access == .readWrite)
        #expect(loaded!.vaults[1].github == "detailyang/awesome-cheatsheet")
        #expect(loaded!.vaults[2].path == "~/Documents/my-notes")
    }

    @Test func loadNonexistentReturnsNil() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let result = try loadRegistry(globalConfigDir: dir)
        #expect(result == nil)
    }

    // MARK: - findVault

    @Test func findVaultByName() {
        var registry = sampleRegistry()
        let found = registry.findVault(named: "cheatsheets")
        #expect(found != nil)
        #expect(found!.name == "cheatsheets")
    }

    @Test func findVaultNotFound() {
        var registry = sampleRegistry()
        #expect(registry.findVault(named: "nonexistent") == nil)
    }

    // MARK: - primaryVault

    @Test func primaryVaultReturnsCorrectEntry() {
        let registry = sampleRegistry()
        let pv = registry.primaryVault()
        #expect(pv != nil)
        #expect(pv!.name == "personal")
    }

    @Test func primaryVaultMissingWhenNotRegistered() {
        let registry = VaultRegistry(primary: "ghost", vaults: [])
        #expect(registry.primaryVault() == nil)
    }

    // MARK: - addVault

    @Test func addVaultSuccess() throws {
        var registry = sampleRegistry()
        let newVault = VaultEntry(name: "work", type: .github, github: "company/notes", access: .readWrite)
        try registry.addVault(newVault)
        #expect(registry.vaults.count == 4)
        #expect(registry.findVault(named: "work") != nil)
    }

    @Test func addVaultDuplicateNameThrows() throws {
        var registry = sampleRegistry()
        let dup = VaultEntry(name: "personal", type: .local, path: "~/other", access: .readOnly)
        #expect(throws: (any Error).self) {
            try registry.addVault(dup)
        }
    }

    // MARK: - removeVault

    @Test func removeVaultSuccess() throws {
        var registry = sampleRegistry()
        try registry.removeVault(named: "cheatsheets")
        #expect(registry.vaults.count == 2)
        #expect(registry.findVault(named: "cheatsheets") == nil)
    }

    @Test func removeVaultNotFoundThrows() throws {
        var registry = sampleRegistry()
        #expect(throws: (any Error).self) {
            try registry.removeVault(named: "nonexistent")
        }
    }

    // MARK: - setPrimary

    @Test func setPrimarySuccess() throws {
        var registry = sampleRegistry()
        try registry.setPrimary("cheatsheets")
        #expect(registry.primary == "cheatsheets")
    }

    @Test func setPrimaryInvalidNameThrows() throws {
        var registry = sampleRegistry()
        #expect(throws: (any Error).self) {
            try registry.setPrimary("ghost")
        }
    }

    // MARK: - Path resolution

    @Test func resolvedPathICloud() {
        let entry = VaultEntry(name: "personal", type: .icloud, access: .readWrite)
        let path = resolvedPath(for: entry)
        #expect(path.contains("iCloud~dev.pcca.mahonotes"))
        #expect(path.contains("/vaults/personal/"))
        #expect(!path.hasPrefix("~"))
    }

    @Test func resolvedPathGitHub() {
        let entry = VaultEntry(name: "cheatsheets", type: .github, github: "detailyang/awesome-cheatsheet", access: .readOnly)
        let path = resolvedPath(for: entry)
        #expect(path.contains("/.maho/vaults/cheatsheets/"))
        #expect(!path.hasPrefix("~"))
    }

    @Test func resolvedPathLocal() {
        let entry = VaultEntry(name: "local-notes", type: .local, path: "~/Documents/my-notes", access: .readWrite)
        let path = resolvedPath(for: entry)
        #expect(!path.hasPrefix("~"))
        #expect(path.contains("Documents/my-notes"))
    }

    // MARK: - Fallback: no iCloud → globalConfigDir

    @Test func fallbackToGlobalConfigDir() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let registry = sampleRegistry()
        // Save directly to globalConfigDir (simulating no iCloud)
        try saveRegistry(registry, globalConfigDir: dir)

        // Should load from globalConfigDir
        let loaded = try loadRegistry(globalConfigDir: dir)
        #expect(loaded != nil)
        #expect(loaded!.primary == "personal")
    }

    // MARK: - Cache file written on save

    @Test func cacheFileWrittenOnSave() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let registry = sampleRegistry()
        try saveRegistry(registry, globalConfigDir: dir)

        let cachePath = (dir as NSString).appendingPathComponent("vaults-cache.yaml")
        #expect(FileManager.default.fileExists(atPath: cachePath), "cache file should exist after save")

        let content = try String(contentsOfFile: cachePath, encoding: .utf8)
        #expect(content.contains("personal"))
    }
}
