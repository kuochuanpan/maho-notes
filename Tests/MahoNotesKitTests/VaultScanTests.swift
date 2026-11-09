import Testing
import Foundation
import Yams
@testable import MahoNotesKit

/// Finding and fixing vaults, collections and notes that don't show up.
/// Every test works in a temp dir; stores get injected iCloud and local storage bases.
@Suite("VaultScan")
struct VaultScanTests {

    // MARK: - Helpers

    private func makeTempDir() throws -> String {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp.path
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Writes files (relative path → content) under `root`.
    private func write(_ files: [String: String], in root: String) throws {
        for (relative, content) in files {
            try write(Data(content.utf8), to: relative, in: root)
        }
    }

    private func write(_ data: Data, to relative: String, in root: String) throws {
        let path = (root as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
    }

    private func exists(_ relative: String, in root: String) -> Bool {
        FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(relative))
    }

    private func read(_ relative: String, in root: String) throws -> String {
        try String(contentsOfFile: (root as NSString).appendingPathComponent(relative), encoding: .utf8)
    }

    private let config = """
    title: Research
    github:
      repo: user/research
    collections:
    - id: notes
      name: Notes
      icon: book
    """

    private func kinds(_ issues: [VaultIssue]) -> [String: VaultIssue.Kind] {
        Dictionary(uniqueKeysWithValues: issues.map { ($0.path, $0.kind) })
    }

    // MARK: - Clean vault

    @Test func cleanVaultHasNoIssues() throws {
        let vault = try makeTempDir()
        defer { cleanup(vault) }
        try write([
            "maho.yaml": config,
            "README.md": "# repo readme",
            "LICENSE.md": "license",
            "notes/_index.md": "---\norder:\n  - a.md\n---\n",
            "notes/a.md": "---\ntitle: A\n---\nbody",
            "notes/README.md": "not a note",
            "_assets/x.md": "assets folders aren't collections",
            ".maho/index.md": "app data",
        ], in: vault)

        #expect(Vault(path: vault).findIssues().isEmpty)
    }

    // MARK: - Collections

    @Test func findsAndFixesCollectionMissingFromConfig() throws {
        let vault = try makeTempDir()
        defer { cleanup(vault) }
        try write([
            "maho.yaml": config,
            "notes/a.md": "a",
            "模擬日誌/_index.md": "---\ntitle: Simulation Log\n---\n",
            "模擬日誌/day1.md": "day 1",
            "scripts/build.sh": "no notes here",
        ], in: vault)

        let issues = Vault(path: vault).findIssues()
        #expect(issues.count == 1)
        let issue = try #require(issues.first)
        #expect(issue.kind == .unlistedCollection)
        #expect(issue.path == "模擬日誌")
        #expect(issue.detail == "Simulation Log")

        try Vault(path: vault).fix(issue)

        let yaml = try #require(try Yams.load(yaml: read("maho.yaml", in: vault)) as? [String: Any])
        let ids = (yaml["collections"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
        #expect(ids == ["notes", "模擬日誌"])
        // Other keys survive the rewrite
        #expect(yaml["title"] as? String == "Research")
        #expect((yaml["github"] as? [String: Any])?["repo"] as? String == "user/research")
        #expect(Vault(path: vault).findIssues().isEmpty)
    }

    @Test func findsAndFixesListedCollectionWithoutFolder() throws {
        let vault = try makeTempDir()
        defer { cleanup(vault) }
        try write(["maho.yaml": config + "\n- id: reading\n  name: Reading\n", "notes/a.md": "a"], in: vault)

        let issue = try #require(Vault(path: vault).findIssues().first)
        #expect(issue.kind == .collectionFolderMissing)
        #expect(issue.path == "reading")
        #expect(issue.detail == "Reading")

        try Vault(path: vault).fix(issue)
        #expect(exists("reading", in: vault))
        #expect(Vault(path: vault).findIssues().isEmpty)
    }

    @Test func unreadableConfigSkipsCollectionChecksAndIsNeverOverwritten() throws {
        let vault = try makeTempDir()
        defer { cleanup(vault) }
        let broken = "collections: [unclosed\ntitle: x"
        try write(["maho.yaml": broken, "loose/a.md": "a"], in: vault)

        let issues = Vault(path: vault).findIssues()
        #expect(issues.map(\.kind) == [.unreadableConfig])
        #expect(issues.first?.isFixable == false)

        // A fix that would write maho.yaml must refuse rather than replace it
        let addLoose = VaultIssue(kind: .unlistedCollection, path: "loose", detail: "Loose", isFixable: true)
        #expect(throws: VaultScanError.self) { try Vault(path: vault).fix(addLoose) }
        #expect(try read("maho.yaml", in: vault) == broken)
    }

    @Test func configPlaceholderIsReportedForDownload() throws {
        let vault = try makeTempDir()
        defer { cleanup(vault) }
        try write([".maho.yaml.icloud": "", "notes/a.md": "a"], in: vault)

        #expect(Vault(path: vault).findIssues().map(\.kind) == [.configNotDownloaded])
    }

    // MARK: - Notes

    @Test func findsAndMovesNoteAtVaultRoot() throws {
        let vault = try makeTempDir()
        defer { cleanup(vault) }
        try write([
            "maho.yaml": config,
            "notes/a.md": "a",
            "notes/CHANGELOG.md": "a note that happens to be called changelog",
            "oh-my-gacha.md": "---\ntitle: Oh My Gacha\n---\nbody",
            "CHANGELOG.md": "repo changelog",
        ], in: vault)

        let issues = Vault(path: vault).findIssues()
        #expect(kinds(issues) == ["oh-my-gacha.md": .noteOutsideCollections])

        let failures = Vault(path: vault).fix(issues, unsortedCollectionName: "未分類")
        #expect(failures.isEmpty)
        #expect(exists("unsorted/oh-my-gacha.md", in: vault))
        #expect(!exists("oh-my-gacha.md", in: vault))

        let yaml = try #require(try Yams.load(yaml: read("maho.yaml", in: vault)) as? [String: Any])
        let unsorted = (yaml["collections"] as? [[String: Any]])?.first { $0["id"] as? String == "unsorted" }
        #expect(unsorted?["name"] as? String == "未分類")
        #expect(unsorted?["icon"] as? String == "tray")

        // The note now shows up in the app's tree
        let tree = try Vault(path: vault).buildFileTree()
        #expect(tree.first { $0.id == "unsorted" }?.children.map(\.id) == ["unsorted/oh-my-gacha.md"])
        #expect(Vault(path: vault).findIssues().isEmpty)
    }

    @Test func movingRootNoteReusesExistingUnsortedCollection() throws {
        let vault = try makeTempDir()
        defer { cleanup(vault) }
        try write([
            "maho.yaml": config + "\n- id: unsorted\n  name: Inbox\n",
            "unsorted/oh-my-gacha.md": "older note with the same name",
            "oh-my-gacha.md": "root note",
        ], in: vault)

        let issue = try #require(Vault(path: vault).findIssues().first { $0.kind == .noteOutsideCollections })
        try Vault(path: vault).fix(issue)

        #expect(try read("unsorted/oh-my-gacha.md", in: vault) == "older note with the same name")
        #expect(try read("unsorted/oh-my-gacha-1.md", in: vault).contains("root note"))
        let yaml = try read("maho.yaml", in: vault)
        #expect(yaml.components(separatedBy: "id: unsorted").count == 2, "unsorted must not be added twice")
    }

    @Test func findsAndRenamesOtherMarkdownExtensions() throws {
        let vault = try makeTempDir()
        defer { cleanup(vault) }
        try write([
            "maho.yaml": config,
            "notes/a.markdown": "a",
            "notes/b.MD": "b",
            "notes/c.mdown": "c",
            "notes/c.md": "an existing c",
            "notes/photo.png": "not markdown",
        ], in: vault)

        let issues = Vault(path: vault).findIssues()
        #expect(kinds(issues) == [
            "notes/a.markdown": .nonStandardExtension,
            "notes/b.MD": .nonStandardExtension,
            "notes/c.mdown": .nonStandardExtension,
        ])

        #expect(Vault(path: vault).fix(issues).isEmpty)
        #expect(try read("notes/a.md", in: vault) == "a")
        #expect(try read("notes/b.md", in: vault) == "b")
        #expect(try read("notes/c.md", in: vault) == "an existing c")
        #expect(try read("notes/c-1.md", in: vault) == "c")
        let names = try FileManager.default.contentsOfDirectory(atPath: (vault as NSString).appendingPathComponent("notes"))
        #expect(!names.contains("b.MD") && names.contains("b.md"), "case-only rename must keep the file, not create b-1.md")
        #expect(Vault(path: vault).findIssues().isEmpty)
    }

    @Test func convertsUTF16NoteAndReportsUnknownEncoding() throws {
        let vault = try makeTempDir()
        defer { cleanup(vault) }
        try write(["maho.yaml": config], in: vault)
        let text = "---\ntitle: 筆記\n---\n中文內容"
        var utf16 = Data([0xFF, 0xFE])
        utf16.append(text.data(using: .utf16LittleEndian)!)
        try write(utf16, to: "notes/utf16.md", in: vault)
        try write(Data([0xA4, 0xA4, 0xA4, 0xE5, 0xFF]), to: "notes/big5.md", in: vault)

        let issues = Vault(path: vault).findIssues()
        #expect(kinds(issues) == ["notes/utf16.md": .notUTF8, "notes/big5.md": .notUTF8])
        #expect(issues.first { $0.path == "notes/utf16.md" }?.isFixable == true)
        #expect(issues.first { $0.path == "notes/big5.md" }?.isFixable == false)

        #expect(Vault(path: vault).fix(issues).isEmpty, "unfixable issues are skipped, not failed")
        #expect(try read("notes/utf16.md", in: vault) == text)
        #expect(try Vault(path: vault).allNotes().map(\.title) == ["筆記"])
        #expect(Vault(path: vault).findIssues().map(\.path) == ["notes/big5.md"])
    }

    @Test func reportsNotesICloudHasNotDownloaded() throws {
        let vault = try makeTempDir()
        defer { cleanup(vault) }
        try write([
            "maho.yaml": config,
            "notes/a.md": "a",
            "notes/.b.md.icloud": "",
            "notes/.photo.png.icloud": "",
            ".README.md.icloud": "",
        ], in: vault)

        let issues = Vault(path: vault).findIssues()
        #expect(kinds(issues) == ["notes/b.md": .notDownloaded])
        #expect(issues.first?.isFixable == true)
    }

    // MARK: - VaultStore: unregistered vaults

    private struct Stores {
        let tmp: String
        let iCloudBase: String
        let localBase: String
        let store: VaultStore
    }

    private func makeStores(cloud: CloudSyncMode) async throws -> Stores {
        let tmp = try makeTempDir()
        let iCloudBase = (tmp as NSString).appendingPathComponent("icloud")
        let localBase = (tmp as NSString).appendingPathComponent("local")
        let store = VaultStore(globalConfigDir: tmp, iCloudDocumentsBase: iCloudBase, localStorageBase: localBase)
        try await store.setCloudSyncMode(cloud)
        return Stores(tmp: tmp, iCloudBase: iCloudBase, localBase: localBase, store: store)
    }

    @Test func findsUnregisteredVaultsAndInfersTheirType() async throws {
        let s = try await makeStores(cloud: .icloud)
        defer { cleanup(s.tmp) }
        try write([
            "vaults/Personal/maho.yaml": "collections: []",
            "vaults/Personal/notes/a.md": "registered already",
            "vaults/getting-started/maho.yaml": "title: Getting Started",
            "vaults/getting-started/getting-started/001.md": "tutorial",
            "vaults/Shared/maho.yaml": "collections: []",
            "vaults/Shared/notes/x.md": "in iCloud",
            "vaults/not-a-vault/random.md": "no maho.yaml",
        ], in: s.iCloudBase)
        try write([
            "vaults/Software Development Vault/maho.yaml": "github:\n  repo: user/dev\n",
            "vaults/Software Development Vault/llm/a.md": "a",
            "vaults/Software Development Vault/llm/b.md": "b",
            "vaults/Offline/maho.yaml": "github:\n  repo: ''\n",
            "vaults/Offline/notes/a.md": "a",
            "vaults/shared/maho.yaml": "collections: []",
            "vaults/personal/maho.yaml": "collections: []",
        ], in: s.localBase)
        try await s.store.saveRegistry(VaultRegistry(primary: "Personal", vaults: [
            VaultEntry(name: "Personal", type: .icloud, access: .readWrite),
        ]))

        let found = try await s.store.findMissingItems().unregisteredVaults
        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0) })

        #expect(Set(byName.keys) == ["getting-started", "Shared", "Software Development Vault", "Offline"],
                "registered names (any case), folders without maho.yaml, and local twins of iCloud folders are skipped")
        #expect(byName["getting-started"]?.type == .icloud)
        #expect(byName["getting-started"]?.title == "Getting Started")
        #expect(byName["Shared"]?.type == .icloud)
        #expect(byName["Software Development Vault"]?.type == .github)
        #expect(byName["Software Development Vault"]?.github == "user/dev")
        #expect(byName["Software Development Vault"]?.noteCount == 2)
        #expect(byName["Software Development Vault"]?.lastModified != nil)
        #expect(byName["Offline"]?.type == .device)
        #expect(byName["Offline"]?.github == nil)
    }

    @Test func iCloudFoldersAreIgnoredWhileCloudSyncIsOff() async throws {
        let s = try await makeStores(cloud: .off)
        defer { cleanup(s.tmp) }
        try write(["vaults/Shared/maho.yaml": "collections: []"], in: s.iCloudBase)
        try write(["vaults/Offline/maho.yaml": "collections: []"], in: s.localBase)

        let found = try await s.store.findMissingItems().unregisteredVaults
        #expect(found.map(\.name) == ["Offline"])
        #expect(found.first?.type == .device)
    }

    @Test func addFoundVaultRegistersGitHubVaultWithItsRepo() async throws {
        let s = try await makeStores(cloud: .icloud)
        defer { cleanup(s.tmp) }
        try write(["vaults/Dev/maho.yaml": "github:\n  repo: user/dev\n", "vaults/Dev/llm/a.md": "a"], in: s.localBase)
        try await s.store.saveRegistry(VaultRegistry(primary: "Personal", vaults: [
            VaultEntry(name: "Personal", type: .icloud, access: .readWrite),
        ]))

        let found = try #require(try await s.store.findMissingItems().unregisteredVaults.first)
        try await s.store.addFoundVault(found)

        let registry = try #require(try await s.store.loadRegistry())
        let entry = try #require(registry.findVault(named: "Dev"))
        #expect(entry.type == .github)
        #expect(entry.github == "user/dev")
        #expect(registry.primary == "Personal")
        #expect(s.store.resolvedPath(for: entry).hasPrefix(s.localBase))
        #expect(try await s.store.findMissingItems().unregisteredVaults.isEmpty)
    }

    @Test func addFoundDeviceVaultCopiesItIntoICloudWhenCloudSyncIsOn() async throws {
        let s = try await makeStores(cloud: .icloud)
        defer { cleanup(s.tmp) }
        try write(["vaults/Offline/maho.yaml": "collections: []", "vaults/Offline/notes/a.md": "a"], in: s.localBase)

        let found = try #require(try await s.store.findMissingItems().unregisteredVaults.first)
        try await s.store.addFoundVault(found)

        let entry = try #require(try await s.store.loadRegistry()?.findVault(named: "Offline"))
        #expect(entry.type == .icloud)
        #expect(exists("vaults/Offline/notes/a.md", in: s.iCloudBase))
        #expect(exists("vaults/Offline/notes/a.md", in: s.localBase), "the local copy is left in place")
        #expect(try await s.store.findMissingItems().unregisteredVaults.isEmpty)
    }

    @Test func addFoundDeviceVaultStaysLocalWhenCloudSyncIsOff() async throws {
        let s = try await makeStores(cloud: .off)
        defer { cleanup(s.tmp) }
        try write(["vaults/Offline/maho.yaml": "collections: []"], in: s.localBase)

        let found = try #require(try await s.store.findMissingItems().unregisteredVaults.first)
        try await s.store.addFoundVault(found)

        #expect(try await s.store.loadRegistry()?.findVault(named: "Offline")?.type == .device)
        #expect(!FileManager.default.fileExists(atPath: s.iCloudBase))
    }

    // MARK: - VaultStore: content of registered vaults

    @Test func reportsContentIssuesOfReadWriteVaultsOnly() async throws {
        let s = try await makeStores(cloud: .off)
        defer { cleanup(s.tmp) }
        try write(["vaults/Mine/maho.yaml": "collections: []", "vaults/Mine/root.md": "r"], in: s.localBase)
        try write(["vaults/Theirs/maho.yaml": "collections: []", "vaults/Theirs/root.md": "r"], in: s.localBase)
        try await s.store.saveRegistry(VaultRegistry(primary: "Mine", vaults: [
            VaultEntry(name: "Mine", type: .device, access: .readWrite, displayName: "My Notes"),
            VaultEntry(name: "Theirs", type: .github, github: "x/y", access: .readOnly),
            VaultEntry(name: "Gone", type: .device, access: .readWrite),
        ]))

        let report = try await s.store.findMissingItems()
        #expect(report.unregisteredVaults.isEmpty)
        #expect(report.vaults.map(\.vaultName) == ["Mine"])
        #expect(report.vaults.first?.displayName == "My Notes")
        #expect(report.vaults.first?.issues.map(\.kind) == [.noteOutsideCollections])
        #expect(report.vaults.first?.vaultPath.hasPrefix(s.localBase) == true)

        let one = try await s.store.findMissingItems(vaultName: "Mine")
        #expect(one.vaults.map(\.vaultName) == ["Mine"])
        #expect(try await s.store.findMissingItems(vaultName: "Theirs").isEmpty)
    }
}
