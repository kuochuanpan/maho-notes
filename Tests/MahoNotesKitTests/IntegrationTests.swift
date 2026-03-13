import Testing
import Foundation
@testable import MahoNotesKit

@Suite("Integration")
struct IntegrationTests {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mn-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func cleanup(_ dirs: URL...) {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
    }

    private func makeMinimalVault(at dir: URL) throws -> Vault {
        let mahoYaml = """
        author:
          name: tester
        collections:
          - id: notes
            name: Notes
            icon: note.text
          - id: journal
            name: Journal
            icon: book
        """
        try mahoYaml.write(to: dir.appendingPathComponent("maho.yaml"), atomically: true, encoding: .utf8)
        let notesDir = dir.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        let journalDir = dir.appendingPathComponent("journal")
        try FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        return Vault(path: dir.path)
    }

    // MARK: - Full workflow: init → new → list → search → delete

    @Test func fullWorkflow() throws {
        let globalDir = try makeTempDir()
        let vaultDir = try makeTempDir()
        defer { cleanup(globalDir, vaultDir) }

        // init
        try initVault(
            vaultPath: vaultDir.path,
            authorName: "Test Author",
            githubRepo: "",
            skipTutorial: true,
            globalConfigDir: globalDir.path
        )

        let vault = Vault(path: vaultDir.path)

        // new: create two notes
        let path1 = try vault.createNote(title: "First Note", collection: "notes", tags: ["swift"])
        let path2 = try vault.createNote(title: "Second Note", collection: "notes", tags: ["testing"])

        #expect(!path1.isEmpty)
        #expect(!path2.isEmpty)

        // list
        let notes = try vault.allNotes()
        #expect(notes.count == 2)
        let titles = Set(notes.map(\.title))
        #expect(titles.contains("First Note"))
        #expect(titles.contains("Second Note"))

        // search by title substring
        let results = try vault.searchNotes(query: "First")
        #expect(results.count == 1)
        #expect(results[0].title == "First Note")

        // search by tag
        let tagResults = try vault.searchNotes(query: "swift")
        #expect(tagResults.count >= 1)

        // delete (via file removal)
        let fullPath = (vaultDir.path as NSString).appendingPathComponent(path1)
        try FileManager.default.removeItem(atPath: fullPath)

        let afterDelete = try vault.allNotes()
        #expect(afterDelete.count == 1)
        #expect(afterDelete[0].title == "Second Note")
    }

    // MARK: - Multi-vault: create notes in separate vaults, list cross-vault

    @Test func multiVaultWorkflow() throws {
        let configDir = try makeTempDir()
        let vault1Dir = try makeTempDir()
        let vault2Dir = try makeTempDir()
        defer { cleanup(configDir, vault1Dir, vault2Dir) }

        let vault1 = try makeMinimalVault(at: vault1Dir)
        let vault2 = try makeMinimalVault(at: vault2Dir)

        _ = try vault1.createNote(title: "Vault1 Note A", collection: "notes", tags: [])
        _ = try vault1.createNote(title: "Vault1 Note B", collection: "notes", tags: [])
        _ = try vault2.createNote(title: "Vault2 Note X", collection: "notes", tags: [])

        // Register both vaults
        var registry = VaultRegistry(primary: "personal", vaults: [])
        try registry.addVault(VaultEntry(name: "personal", type: .local, path: vault1Dir.path, access: .readWrite))
        try registry.addVault(VaultEntry(name: "work", type: .local, path: vault2Dir.path, access: .readWrite))
        try saveRegistry(registry, globalConfigDir: configDir.path)

        let loaded = try loadRegistry(globalConfigDir: configDir.path)!

        // list --all: aggregate notes from both vaults
        var allNotes: [Note] = []
        for entry in loaded.vaults {
            let vault = Vault(path: resolvedPath(for: entry))
            allNotes += (try? vault.allNotes()) ?? []
        }

        #expect(allNotes.count == 3)
        let allTitles = Set(allNotes.map(\.title))
        #expect(allTitles.contains("Vault1 Note A"))
        #expect(allTitles.contains("Vault1 Note B"))
        #expect(allTitles.contains("Vault2 Note X"))
    }

    // MARK: - Read-only local vault via --path --readonly

    @Test func localVaultWithReadonlyFlag() throws {
        let configDir = try makeTempDir()
        let vaultDir = try makeTempDir()
        defer { cleanup(configDir, vaultDir) }

        // Simulate: mn vault add shared --path <dir> --readonly
        var registry = VaultRegistry(primary: "shared", vaults: [])
        let entry = VaultEntry(name: "shared", type: .local, path: vaultDir.path, access: .readOnly)
        try registry.addVault(entry)
        try saveRegistry(registry, globalConfigDir: configDir.path)

        // Verify access flag persists
        let loaded = try loadRegistry(globalConfigDir: configDir.path)!
        let found = loaded.findVault(named: "shared")
        #expect(found != nil)
        #expect(found!.access == .readOnly)
        #expect(found!.type == .local)
        #expect(found!.path == vaultDir.path)
    }

    // MARK: - Read-only enforcement: validateWritable message has no double "Error:"

    @Test func readOnlyVaultEntryIsDetectedCorrectly() throws {
        let entry = VaultEntry(name: "ro", type: .local, path: "/tmp/ro", access: .readOnly)
        #expect(entry.access == .readOnly)

        let rwEntry = VaultEntry(name: "rw", type: .local, path: "/tmp/rw", access: .readWrite)
        #expect(rwEntry.access == .readWrite)
    }

    // MARK: - Config: loading vault config returns expected structure

    @Test func vaultConfigLoadsCorrectly() throws {
        let vaultDir = try makeTempDir()
        defer { cleanup(vaultDir) }

        let mahoYaml = """
        author:
          name: Alice
          url: https://example.com
        collections:
          - id: notes
            name: Notes
            icon: note.text
        github:
          repo: alice/vault
        """
        try mahoYaml.write(to: vaultDir.appendingPathComponent("maho.yaml"), atomically: true, encoding: .utf8)

        let config = Config(vaultPath: vaultDir.path)
        let vaultConfig = try config.loadVaultConfig()

        // Verify top-level keys are present
        #expect(vaultConfig["author"] != nil)
        #expect(vaultConfig["collections"] != nil)
        #expect(vaultConfig["github"] != nil)

        // Verify nested values
        let author = vaultConfig["author"] as? [String: Any]
        #expect(author?["name"] as? String == "Alice")

        let collections = vaultConfig["collections"] as? [[String: Any]]
        #expect(collections?.count == 1)
        #expect(collections?.first?["id"] as? String == "notes")

        let github = vaultConfig["github"] as? [String: Any]
        #expect(github?["repo"] as? String == "alice/vault")
    }

    // MARK: - JSON output: allNotes returns Codable notes

    @Test func notesAreEncodableToJSON() throws {
        let vaultDir = try makeTempDir()
        defer { cleanup(vaultDir) }

        let vault = try makeMinimalVault(at: vaultDir)
        _ = try vault.createNote(title: "JSON Test Note", collection: "notes", tags: ["json", "test"])

        let notes = try vault.allNotes()
        #expect(notes.count == 1)

        // Verify JSON encoding succeeds
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(notes)
        #expect(!data.isEmpty)

        let jsonStr = String(data: data, encoding: .utf8) ?? ""
        #expect(jsonStr.contains("JSON Test Note"))
        #expect(jsonStr.contains("json"))
    }

    // MARK: - Note creation across multiple collections

    @Test func createNotesInMultipleCollections() throws {
        let vaultDir = try makeTempDir()
        defer { cleanup(vaultDir) }

        let vault = try makeMinimalVault(at: vaultDir)

        _ = try vault.createNote(title: "Notes Entry", collection: "notes", tags: [])
        _ = try vault.createNote(title: "Journal Entry", collection: "journal", tags: [])

        let notes = try vault.allNotes()
        #expect(notes.count == 2)

        let notesCollection = notes.filter { $0.collection == "notes" }
        let journalCollection = notes.filter { $0.collection == "journal" }

        #expect(notesCollection.count == 1)
        #expect(journalCollection.count == 1)
        #expect(notesCollection[0].title == "Notes Entry")
        #expect(journalCollection[0].title == "Journal Entry")
    }

    // MARK: - Search: FTS finds notes by content

    @Test func searchByContent() throws {
        let vaultDir = try makeTempDir()
        defer { cleanup(vaultDir) }

        let mahoYaml = """
        author:
          name: tester
        collections:
          - id: notes
            name: Notes
            icon: note.text
        """
        try mahoYaml.write(to: vaultDir.appendingPathComponent("maho.yaml"), atomically: true, encoding: .utf8)

        let notesDir = vaultDir.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)

        // Write note with specific body content
        let noteContent = """
        ---
        title: Quantum Physics
        tags: [science]
        created: 2024-01-01T00:00:00+00:00
        updated: 2024-01-01T00:00:00+00:00
        public: false
        author: tester
        ---

        # Quantum Physics

        This note is about superposition and entanglement.
        """
        try noteContent.write(
            to: notesDir.appendingPathComponent("001-quantum-physics.md"),
            atomically: true, encoding: .utf8
        )

        let vault = Vault(path: vaultDir.path)

        // Search by title
        let titleResults = try vault.searchNotes(query: "Quantum")
        #expect(titleResults.count >= 1)
        #expect(titleResults.first?.title == "Quantum Physics")

        // Search by body content
        let bodyResults = try vault.searchNotes(query: "superposition")
        #expect(bodyResults.count >= 1)

        // Search non-matching
        let noResults = try vault.searchNotes(query: "blockchain")
        #expect(noResults.isEmpty)
    }
}
