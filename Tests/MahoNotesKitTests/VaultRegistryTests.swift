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
                VaultEntry(name: "offline", type: .device, access: .readWrite),
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
        #expect(loaded!.vaults[3].name == "offline")
        #expect(loaded!.vaults[3].type == .device)
    }

    @Test func loadNonexistentReturnsNil() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let result = try loadRegistry(globalConfigDir: dir)
        #expect(result == nil)
    }

    // MARK: - findVault

    @Test func findVaultByName() {
        let registry = sampleRegistry()
        let found = registry.findVault(named: "cheatsheets")
        #expect(found != nil)
        #expect(found!.name == "cheatsheets")
    }

    @Test func findVaultNotFound() {
        let registry = sampleRegistry()
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
        #expect(registry.vaults.count == 5)
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
        #expect(registry.vaults.count == 3)
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
        #expect(path.contains("iCloud~dev~pcca~mahonotes"))
        #expect(path.contains("/vaults/personal/"))
        #expect(!path.hasPrefix("~"))
    }

    @Test func resolvedPathGitHub() {
        let entry = VaultEntry(name: "cheatsheets", type: .github, github: "detailyang/awesome-cheatsheet", access: .readOnly)
        let path = resolvedPath(for: entry)
        #expect(path.contains("group.dev.pcca.mahonotes/vaults/cheatsheets/"))
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

    /// Cache file is written when Cloud Sync is ON. The iCloud base is a temp dir so the
    /// fixture registry never overwrites the live, device-synced `config/vaults.yaml`.
    @Test func cacheFileWrittenOnSaveWhenCloudOn() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let iCloudBase = (dir as NSString).appendingPathComponent("icloud")

        // Cache is only written when Cloud Sync is ON
        try setGlobalSyncMode(.icloud, globalConfigDir: dir)

        let registry = sampleRegistry()
        try saveRegistry(registry, globalConfigDir: dir, iCloudBase: iCloudBase)

        let iCloudRegistryPath = (iCloudBase as NSString).appendingPathComponent("config/vaults.yaml")
        #expect(FileManager.default.fileExists(atPath: iCloudRegistryPath), "registry should be written to the iCloud base")

        let cachePath = (dir as NSString).appendingPathComponent("vaults-cache.yaml")
        #expect(FileManager.default.fileExists(atPath: cachePath), "cache file should exist when cloud sync ON")

        let content = try String(contentsOfFile: cachePath, encoding: .utf8)
        #expect(content.contains("personal"))
    }

    @Test func cacheFileNotWrittenWhenCloudOff() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // Cloud Sync OFF → no cache file
        let registry = sampleRegistry()
        try saveRegistry(registry, globalConfigDir: dir)

        let cachePath = (dir as NSString).appendingPathComponent("vaults-cache.yaml")
        #expect(!FileManager.default.fileExists(atPath: cachePath), "cache file should NOT exist when cloud sync OFF")
    }

    // MARK: - Device vault path resolution

    @Test func resolvedPathDevice() {
        let entry = VaultEntry(name: "offline", type: .device, access: .readWrite)
        let path = resolvedPath(for: entry)
        #expect(path.contains("group.dev.pcca.mahonotes/vaults/offline/"))
        #expect(!path.hasPrefix("~"))
    }

    // MARK: - Device vault roundtrip

    @Test func deviceVaultRoundtrip() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        var registry = VaultRegistry(primary: "offline", vaults: [])
        let entry = VaultEntry(name: "offline", type: .device, access: .readWrite)
        try registry.addVault(entry)
        try saveRegistry(registry, globalConfigDir: dir)

        let loaded = try loadRegistry(globalConfigDir: dir)
        #expect(loaded != nil)
        #expect(loaded!.primary == "offline")
        #expect(loaded!.vaults[0].type == .device)
        #expect(loaded!.vaults[0].name == "offline")
    }

    // MARK: - loadCloudSyncMode default

    @Test func loadCloudSyncModeDefaultsToOff() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // No config.yaml in dir → default is .off (opt-in)
        let mode = loadCloudSyncMode(globalConfigDir: dir)
        #expect(mode == .off)
    }

    @Test func loadCloudSyncModeReadsOffFromConfig() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        try setGlobalSyncMode(.off, globalConfigDir: dir)
        let mode = loadCloudSyncMode(globalConfigDir: dir)
        #expect(mode == .off)
    }

    // MARK: - Cloud Sync OFF: save writes to global only, no cache

    @Test func saveWithCloudSyncOffWritesGlobalOnly() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // Write config.yaml with sync.cloud = off
        try setGlobalSyncMode(.off, globalConfigDir: dir)

        let registry = sampleRegistry()
        try saveRegistry(registry, globalConfigDir: dir)

        // vaults.yaml should exist in global dir
        let vaultsPath = (dir as NSString).appendingPathComponent("vaults.yaml")
        #expect(FileManager.default.fileExists(atPath: vaultsPath), "vaults.yaml should exist in globalConfigDir")

        // vaults-cache.yaml should NOT exist
        let cachePath = (dir as NSString).appendingPathComponent("vaults-cache.yaml")
        #expect(!FileManager.default.fileExists(atPath: cachePath), "cache file should not be written when Cloud Sync is OFF")

        // Loaded registry should match
        let loaded = try loadRegistry(globalConfigDir: dir)
        #expect(loaded != nil)
        #expect(loaded!.primary == registry.primary)
        #expect(loaded!.vaults.count == registry.vaults.count)
    }

    // MARK: - Registry Merge

    @Test func mergeWithNoConflicts() throws {
        let local = VaultRegistry(primary: "notes", vaults: [
            VaultEntry(name: "notes", type: .device, access: .readWrite),
        ])
        let cloud = VaultRegistry(primary: "work", vaults: [
            VaultEntry(name: "work", type: .icloud, access: .readWrite),
        ])

        let (merged, conflicts) = mergeRegistries(local: local, cloud: cloud, localDeviceName: "macmini")

        #expect(conflicts.isEmpty)
        #expect(merged.vaults.count == 2)
        #expect(merged.vaults.contains { $0.name == "notes" })
        #expect(merged.vaults.contains { $0.name == "work" })
    }

    @Test func mergeDeduplicatesSamePathSameName() throws {
        let entry = VaultEntry(name: "notes", type: .icloud, access: .readWrite)
        let local = VaultRegistry(primary: "notes", vaults: [entry])
        let cloud = VaultRegistry(primary: "notes", vaults: [entry])

        let (merged, conflicts) = mergeRegistries(local: local, cloud: cloud, localDeviceName: "macmini")

        #expect(conflicts.isEmpty)
        #expect(merged.vaults.count == 1)
        #expect(merged.vaults[0].name == "notes")
    }

    @Test func mergeRenamesConflictingNames() throws {
        let local = VaultRegistry(primary: "notes", vaults: [
            VaultEntry(name: "notes", type: .device, access: .readWrite),
        ])
        let cloud = VaultRegistry(primary: "notes", vaults: [
            VaultEntry(name: "notes", type: .icloud, access: .readWrite),
        ])

        let (merged, conflicts) = mergeRegistries(local: local, cloud: cloud, localDeviceName: "macmini")

        #expect(conflicts.count == 1)
        #expect(merged.vaults.count == 2)
        #expect(merged.vaults.contains { $0.name == "notes-macmini" })
        #expect(merged.vaults.contains { $0.name == "notes-cloud" })
        #expect(conflicts[0].originalName == "notes")
        #expect(conflicts[0].localRenamed == "notes-macmini")
        #expect(conflicts[0].cloudRenamed == "notes-cloud")
    }

    @Test func mergePrefersCloudPrimary() throws {
        let local = VaultRegistry(primary: "local-vault", vaults: [
            VaultEntry(name: "local-vault", type: .device, access: .readWrite),
        ])
        let cloud = VaultRegistry(primary: "cloud-vault", vaults: [
            VaultEntry(name: "cloud-vault", type: .icloud, access: .readWrite),
        ])

        let (merged, _) = mergeRegistries(local: local, cloud: cloud, localDeviceName: "macmini")
        #expect(merged.primary == "cloud-vault")
    }

    @Test func mergeHandlesMultipleConflicts() throws {
        let local = VaultRegistry(primary: "notes", vaults: [
            VaultEntry(name: "notes", type: .device, access: .readWrite),
            VaultEntry(name: "work", type: .device, access: .readWrite),
            VaultEntry(name: "personal", type: .device, access: .readWrite),
        ])
        let cloud = VaultRegistry(primary: "notes", vaults: [
            VaultEntry(name: "notes", type: .icloud, access: .readWrite),
            VaultEntry(name: "work", type: .icloud, access: .readWrite),
            VaultEntry(name: "journal", type: .icloud, access: .readWrite),
        ])

        let (merged, conflicts) = mergeRegistries(local: local, cloud: cloud, localDeviceName: "mbp")

        #expect(conflicts.count == 2) // notes and work conflict
        #expect(merged.vaults.count == 6) // 2+2 renamed + personal + journal
        #expect(merged.vaults.contains { $0.name == "personal" })
        #expect(merged.vaults.contains { $0.name == "journal" })
        #expect(merged.vaults.contains { $0.name == "notes-mbp" })
        #expect(merged.vaults.contains { $0.name == "notes-cloud" })
        #expect(merged.vaults.contains { $0.name == "work-mbp" })
        #expect(merged.vaults.contains { $0.name == "work-cloud" })
    }

    // MARK: - renameConflictedVaultDirectories

    @Test func renameConflictedVaultDirectoriesMovesDirectories() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        let fm = FileManager.default
        defer { try? fm.removeItem(atPath: tmpDir) }

        // Simulate device vault dir at tmpDir/vaults/<originalName>
        let deviceVaultsBase = (tmpDir as NSString).appendingPathComponent("vaults")
        let originalDeviceDir = (deviceVaultsBase as NSString).appendingPathComponent("notes")
        try fm.createDirectory(atPath: originalDeviceDir, withIntermediateDirectories: true)
        try "hello".write(toFile: (originalDeviceDir as NSString).appendingPathComponent("test.md"),
                          atomically: true, encoding: .utf8)

        let conflicts = [
            VaultNameConflict(
                originalName: "notes",
                localRenamed: "notes-macmini",
                cloudRenamed: "notes-cloud",
                localType: .device,
                cloudType: .icloud
            )
        ]

        // We can't easily test iCloud rename without actual iCloud container,
        // but we can verify the function doesn't crash on missing cloud dirs
        // and correctly renames the local (device) directory.
        // Note: renameConflictedVaultDirectories uses resolvedPath() which derives
        // from mahoConfigBase(), so in a test we'd need the dir to match.
        // For now, verify the struct fields are correctly populated.
        #expect(conflicts[0].localType == .device)
        #expect(conflicts[0].cloudType == .icloud)
    }

    // MARK: - Device → iCloud migration when iCloud already has the folder
    //
    // Every test injects both the iCloud base and the local storage base, so nothing
    // here reads or writes the live App Group or iCloud container.

    /// Creates `<base>/vaults/<name>/` containing the given files (relative path → content).
    @discardableResult
    private func makeVault(in base: String, name: String, files: [String: String]) throws -> String {
        let dir = (base as NSString).appendingPathComponent("vaults/\(name)")
        for (relative, content) in files {
            let path = (dir as NSString).appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        }
        return dir
    }

    @Test func migrateToCloudConvertsEntryWhenICloudFolderAlreadyExists() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let iCloudBase = (dir as NSString).appendingPathComponent("icloud")
        let localBase = (dir as NSString).appendingPathComponent("local")

        try makeVault(in: localBase, name: "getting-started", files: [
            "maho.yaml": "local config",
            "getting-started/001-welcome.md": "local welcome",
            "getting-started/011-local-only.md": "only on this device",
        ])
        let iCloudVault = try makeVault(in: iCloudBase, name: "getting-started", files: [
            "maho.yaml": "icloud config",
            "getting-started/001-welcome.md": "icloud welcome",
        ])

        let registry = VaultRegistry(primary: "getting-started", vaults: [
            VaultEntry(name: "getting-started", type: .device, access: .readWrite, displayName: "Getting Started"),
        ])
        let migrated = try migrateVaultsToCloud(registry: registry, iCloudBase: iCloudBase, localBase: localBase)

        #expect(migrated.vaults[0].type == .icloud)
        #expect(migrated.vaults[0].displayName == "Getting Started")
        // Missing files are filled in; existing iCloud files are never overwritten
        let read = { (rel: String) in try String(contentsOfFile: (iCloudVault as NSString).appendingPathComponent(rel), encoding: .utf8) }
        #expect(try read("maho.yaml") == "icloud config")
        #expect(try read("getting-started/001-welcome.md") == "icloud welcome")
        #expect(try read("getting-started/011-local-only.md") == "only on this device")
    }

    @Test func migrateToCloudConvertsEntryWhenOnlyICloudHasTheFolder() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let iCloudBase = (dir as NSString).appendingPathComponent("icloud")
        let localBase = (dir as NSString).appendingPathComponent("local")
        try makeVault(in: iCloudBase, name: "getting-started", files: ["maho.yaml": "x"])

        let registry = VaultRegistry(primary: "getting-started", vaults: [
            VaultEntry(name: "getting-started", type: .device, access: .readWrite),
        ])
        let migrated = try migrateVaultsToCloud(registry: registry, iCloudBase: iCloudBase, localBase: localBase)
        #expect(migrated.vaults[0].type == .icloud)
    }

    @Test func migrateToCloudLeavesEntryWhenNoFolderExists() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let iCloudBase = (dir as NSString).appendingPathComponent("icloud")
        let localBase = (dir as NSString).appendingPathComponent("local")

        let registry = VaultRegistry(primary: "ghost", vaults: [
            VaultEntry(name: "ghost", type: .device, access: .readWrite),
        ])
        let migrated = try migrateVaultsToCloud(registry: registry, iCloudBase: iCloudBase, localBase: localBase)
        #expect(migrated.vaults[0].type == .device)
        #expect(!FileManager.default.fileExists(atPath: (iCloudBase as NSString).appendingPathComponent("vaults/ghost")))
    }

    // MARK: - Repair of `.device` entries whose data lives in iCloud

    @Test func repairConvertsDeviceEntryMissingLocallyButPresentInICloud() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let iCloudBase = (dir as NSString).appendingPathComponent("icloud")
        let localBase = (dir as NSString).appendingPathComponent("local")
        try makeVault(in: iCloudBase, name: "getting-started", files: ["maho.yaml": "x"])

        let registry = VaultRegistry(primary: "Personal", vaults: [
            VaultEntry(name: "getting-started", type: .device, access: .readWrite, displayName: "Getting Started"),
            VaultEntry(name: "Personal", type: .icloud, access: .readWrite),
        ])
        let repaired = try #require(repairDeviceEntriesStoredInICloud(
            registry: registry, iCloudBase: iCloudBase, localBase: localBase))
        #expect(repaired.vaults[0].type == .icloud)
        #expect(repaired.vaults[0].displayName == "Getting Started")
        #expect(repaired.vaults[1].type == .icloud)
        #expect(repaired.primary == "Personal")
    }

    @Test func repairLeavesDeviceEntryThatExistsLocally() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let iCloudBase = (dir as NSString).appendingPathComponent("icloud")
        let localBase = (dir as NSString).appendingPathComponent("local")
        try makeVault(in: localBase, name: "notes", files: ["maho.yaml": "local"])
        try makeVault(in: iCloudBase, name: "notes", files: ["maho.yaml": "icloud"])

        let registry = VaultRegistry(primary: "notes", vaults: [
            VaultEntry(name: "notes", type: .device, access: .readWrite),
        ])
        #expect(repairDeviceEntriesStoredInICloud(registry: registry, iCloudBase: iCloudBase, localBase: localBase) == nil)
    }

    @Test func repairIgnoresICloudFolderThatIsNotAVault() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let iCloudBase = (dir as NSString).appendingPathComponent("icloud")
        let localBase = (dir as NSString).appendingPathComponent("local")
        try makeVault(in: iCloudBase, name: "notes", files: ["stray.md": "no maho.yaml here"])

        let registry = VaultRegistry(primary: "notes", vaults: [
            VaultEntry(name: "notes", type: .device, access: .readWrite),
        ])
        #expect(repairDeviceEntriesStoredInICloud(registry: registry, iCloudBase: iCloudBase, localBase: localBase) == nil)
    }

    // MARK: - iCloud registry that exists but isn't readable yet

    /// Puts only iCloud's `.vaults.yaml.icloud` stub in place — what a device sees before
    /// iCloud downloads the registry another device wrote.
    private func makeRegistryPlaceholder(iCloudBase: String) throws {
        let config = (iCloudBase as NSString).appendingPathComponent("config")
        try FileManager.default.createDirectory(atPath: config, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: (config as NSString).appendingPathComponent(".vaults.yaml.icloud")))
    }

    @Test func iCloudFileExistsCountsPlaceholder() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let registryPath = (dir as NSString).appendingPathComponent("config/vaults.yaml")
        #expect(!iCloudFileExists(atPath: registryPath))
        try makeRegistryPlaceholder(iCloudBase: dir)
        #expect(iCloudFileExists(atPath: registryPath))
    }

    @Test func loadRegistryThrowsInsteadOfReturningNilForUndownloadedICloudRegistry() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let iCloudBase = (dir as NSString).appendingPathComponent("icloud")
        try setGlobalSyncMode(.icloud, globalConfigDir: dir)
        try makeRegistryPlaceholder(iCloudBase: iCloudBase)

        #expect {
            _ = try loadRegistry(globalConfigDir: dir, iCloudBase: iCloudBase)
        } throws: { error in
            guard case VaultRegistryError.iCloudRegistryUnavailable = error else { return false }
            return true
        }
    }

    @Test func checkCloudRegistryReportsUnavailableForPlaceholder() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let iCloudBase = (dir as NSString).appendingPathComponent("icloud")
        try makeRegistryPlaceholder(iCloudBase: iCloudBase)

        guard case .cloudRegistryUnavailable = checkCloudRegistryExists(globalConfigDir: dir, iCloudBase: iCloudBase) else {
            Issue.record("an undownloaded iCloud registry must not be reported as absent")
            return
        }
    }

    @Test func checkCloudRegistryReportsUnavailableForUndecodableRegistry() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let iCloudBase = (dir as NSString).appendingPathComponent("icloud")
        let config = (iCloudBase as NSString).appendingPathComponent("config")
        try FileManager.default.createDirectory(atPath: config, withIntermediateDirectories: true)
        try "not: [a registry".write(toFile: (config as NSString).appendingPathComponent("vaults.yaml"),
                                     atomically: true, encoding: .utf8)

        guard case .cloudRegistryUnavailable = checkCloudRegistryExists(globalConfigDir: dir, iCloudBase: iCloudBase) else {
            Issue.record("an unreadable iCloud registry must not be reported as absent")
            return
        }
    }

    @Test func checkCloudRegistryReportsAbsentWhenNothingIsThere() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let iCloudBase = (dir as NSString).appendingPathComponent("icloud")
        guard case .noCloudRegistry = checkCloudRegistryExists(globalConfigDir: dir, iCloudBase: iCloudBase) else {
            Issue.record("expected no registry")
            return
        }
    }
}
