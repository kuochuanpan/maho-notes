import Testing
import Foundation
@testable import MahoNotesKit

@Suite("CrossVault")
struct CrossVaultTests {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cross-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func cleanup(_ dirs: URL...) {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
    }

    /// Creates a minimal vault directory with one note.
    private func makeVaultDir(at dir: URL, noteTitle: String, body: String = "Some content.") throws -> Vault {
        let mahoYaml = """
        author:
          name: test
        collections:
          - id: notes
            name: Notes
            icon: note.text
        """
        try mahoYaml.write(to: dir.appendingPathComponent("maho.yaml"), atomically: true, encoding: .utf8)

        let collDir = dir.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: collDir, withIntermediateDirectories: true)

        let frontmatter = """
        ---
        title: \(noteTitle)
        collection: notes
        created: 2024-01-01T00:00:00+00:00
        updated: 2024-01-01T00:00:00+00:00
        tags: []
        author: test
        ---
        \(body)
        """
        try frontmatter.write(
            to: collDir.appendingPathComponent("001-test.md"),
            atomically: true, encoding: .utf8
        )
        return Vault(path: dir.path)
    }

    // MARK: - Registry resolution

    @Test func resolveVaultNameFromRegistry() throws {
        let configDir = try makeTempDir()
        let vaultDir = try makeTempDir()
        defer { cleanup(configDir, vaultDir) }

        let entry = VaultEntry(name: "personal", type: .local, path: vaultDir.path, access: .readWrite)
        let registry = VaultRegistry(primary: "personal", vaults: [entry])
        try saveRegistry(registry, globalConfigDir: configDir.path)

        let loaded = try loadRegistry(globalConfigDir: configDir.path)
        let found = loaded?.findVault(named: "personal")
        #expect(found != nil)
        #expect(found!.name == "personal")
        #expect(resolvedPath(for: found!) == vaultDir.path)
    }

    @Test func fallbackToNilWhenNoRegistry() throws {
        let configDir = try makeTempDir()
        defer { cleanup(configDir) }

        let result = try loadRegistry(globalConfigDir: configDir.path)
        #expect(result == nil)
    }

    @Test func primaryVaultResolutionFromRegistry() throws {
        let configDir = try makeTempDir()
        let v1 = try makeTempDir()
        let v2 = try makeTempDir()
        defer { cleanup(configDir, v1, v2) }

        let registry = VaultRegistry(
            primary: "second",
            vaults: [
                VaultEntry(name: "first", type: .local, path: v1.path, access: .readWrite),
                VaultEntry(name: "second", type: .local, path: v2.path, access: .readWrite),
            ]
        )
        try saveRegistry(registry, globalConfigDir: configDir.path)

        let loaded = try loadRegistry(globalConfigDir: configDir.path)!
        let primary = loaded.primaryVault()
        #expect(primary?.name == "second")
        #expect(resolvedPath(for: primary!) == v2.path)
    }

    // MARK: - Cross-vault note collection

    @Test func collectsNotesFromMultipleVaults() throws {
        let configDir = try makeTempDir()
        let v1Dir = try makeTempDir()
        let v2Dir = try makeTempDir()
        defer { cleanup(configDir, v1Dir, v2Dir) }

        _ = try makeVaultDir(at: v1Dir, noteTitle: "Alpha Note")
        _ = try makeVaultDir(at: v2Dir, noteTitle: "Beta Note")

        let registry = VaultRegistry(
            primary: "vault1",
            vaults: [
                VaultEntry(name: "vault1", type: .local, path: v1Dir.path, access: .readWrite),
                VaultEntry(name: "vault2", type: .local, path: v2Dir.path, access: .readOnly),
            ]
        )
        try saveRegistry(registry, globalConfigDir: configDir.path)

        let loaded = try loadRegistry(globalConfigDir: configDir.path)!
        var allNotes: [Note] = []
        for entry in loaded.vaults {
            let vault = Vault(path: resolvedPath(for: entry))
            allNotes += (try? vault.allNotes()) ?? []
        }

        #expect(allNotes.count == 2)
        let titles = Set(allNotes.map(\.title))
        #expect(titles.contains("Alpha Note"))
        #expect(titles.contains("Beta Note"))
    }

    @Test func crossVaultSearchFindsAcrossVaults() throws {
        let configDir = try makeTempDir()
        let v1Dir = try makeTempDir()
        let v2Dir = try makeTempDir()
        defer { cleanup(configDir, v1Dir, v2Dir) }

        _ = try makeVaultDir(at: v1Dir, noteTitle: "Sushi Guide", body: "All about sushi and Japanese food.")
        _ = try makeVaultDir(at: v2Dir, noteTitle: "Astronomy Notes", body: "Stars and galaxies far away.")

        let registry = VaultRegistry(
            primary: "food",
            vaults: [
                VaultEntry(name: "food", type: .local, path: v1Dir.path, access: .readWrite),
                VaultEntry(name: "science", type: .local, path: v2Dir.path, access: .readOnly),
            ]
        )
        try saveRegistry(registry, globalConfigDir: configDir.path)

        let loaded = try loadRegistry(globalConfigDir: configDir.path)!

        // Search "sushi" — should only match vault1
        var matches: [(vaultName: String, notes: [Note])] = []
        for entry in loaded.vaults {
            let vault = Vault(path: resolvedPath(for: entry))
            let notes = (try? vault.searchNotes(query: "sushi")) ?? []
            if !notes.isEmpty { matches.append((entry.name, notes)) }
        }
        #expect(matches.count == 1)
        #expect(matches[0].vaultName == "food")

        // Search "stars" — should only match vault2
        var matches2: [(vaultName: String, notes: [Note])] = []
        for entry in loaded.vaults {
            let vault = Vault(path: resolvedPath(for: entry))
            let notes = (try? vault.searchNotes(query: "stars")) ?? []
            if !notes.isEmpty { matches2.append((entry.name, notes)) }
        }
        #expect(matches2.count == 1)
        #expect(matches2[0].vaultName == "science")
    }

    // MARK: - Read-only access enforcement

    @Test func readOnlyEntryHasCorrectAccessFlag() {
        let entry = VaultEntry(name: "shared", type: .github, github: "org/shared", access: .readOnly)
        #expect(entry.access == .readOnly)
    }

    @Test func readWriteEntryHasCorrectAccessFlag() {
        let entry = VaultEntry(name: "mine", type: .local, path: "/tmp/mine", access: .readWrite)
        #expect(entry.access == .readWrite)
    }

    @Test func registryPreservesAccessFlags() throws {
        let configDir = try makeTempDir()
        defer { cleanup(configDir) }

        let registry = VaultRegistry(
            primary: "rw",
            vaults: [
                VaultEntry(name: "rw",  type: .local, path: "/tmp/rw",  access: .readWrite),
                VaultEntry(name: "ro",  type: .github, github: "org/ro", access: .readOnly),
            ]
        )
        try saveRegistry(registry, globalConfigDir: configDir.path)

        let loaded = try loadRegistry(globalConfigDir: configDir.path)!
        #expect(loaded.findVault(named: "rw")?.access == .readWrite)
        #expect(loaded.findVault(named: "ro")?.access == .readOnly)
    }

    // MARK: - allVaultEntries via registry

    @Test func registryReturnsAllEntries() throws {
        let configDir = try makeTempDir()
        defer { cleanup(configDir) }

        let registry = VaultRegistry(
            primary: "a",
            vaults: [
                VaultEntry(name: "a", type: .local, path: "/tmp/a", access: .readWrite),
                VaultEntry(name: "b", type: .local, path: "/tmp/b", access: .readWrite),
                VaultEntry(name: "c", type: .github, github: "org/c", access: .readOnly),
            ]
        )
        try saveRegistry(registry, globalConfigDir: configDir.path)

        let loaded = try loadRegistry(globalConfigDir: configDir.path)!
        #expect(loaded.vaults.count == 3)
    }

    @Test func emptyRegistryHasNoEntries() throws {
        let configDir = try makeTempDir()
        defer { cleanup(configDir) }

        let registry = VaultRegistry(primary: "empty", vaults: [])
        try saveRegistry(registry, globalConfigDir: configDir.path)

        let loaded = try loadRegistry(globalConfigDir: configDir.path)!
        #expect(loaded.vaults.isEmpty)
    }
}
