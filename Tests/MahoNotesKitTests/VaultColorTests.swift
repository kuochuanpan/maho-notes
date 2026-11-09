import Testing
import Foundation
@testable import MahoNotesKit

@Suite("VaultColor")
struct VaultColorTests {

    // MARK: - Helpers

    /// The 18 names older builds offered; registries in the wild store these.
    private static let legacyNames = [
        "red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo",
        "purple", "pink", "brown", "coral", "lavender", "sage", "sky", "slate", "charcoal",
    ]

    /// Vault rail background, `#721F6D`.
    private static let rail = VaultColor(name: "rail", rgb: 0x721F6D)

    private static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// WCAG 2 relative luminance.
    private static func luminance(_ color: VaultColor) -> Double {
        0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    /// OKLab coordinates, for a perceptual distance between two colors.
    private static func oklab(_ color: VaultColor) -> (Double, Double, Double) {
        let r = linear(color.red), g = linear(color.green), b = linear(color.blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    private static func distance(_ a: VaultColor, _ b: VaultColor) -> Double {
        let p = oklab(a), q = oklab(b)
        return ((p.0 - q.0) * (p.0 - q.0) + (p.1 - q.1) * (p.1 - q.1) + (p.2 - q.2) * (p.2 - q.2)).squareRoot()
    }

    private func entry(_ name: String, color: String? = nil) -> VaultEntry {
        VaultEntry(name: name, type: .device, access: .readWrite, color: color)
    }

    // MARK: - Palette

    @Test("palette fills the six-column picker grid with unique names")
    func paletteShape() {
        let names = VaultColor.palette.map(\.name)
        #expect(names.count == 24)
        #expect(names.count % 6 == 0)
        #expect(Set(names).count == names.count)
    }

    @Test("palette keeps every name older builds stored")
    func paletteKeepsLegacyNames() {
        for name in Self.legacyNames {
            #expect(VaultColor.named(name) != nil, "\(name) must stay valid for existing registries")
        }
    }

    @Test("assignment order is a permutation of the palette")
    func assignmentOrderCoversPalette() {
        #expect(VaultColor.assignmentOrder.count == VaultColor.palette.count)
        #expect(Set(VaultColor.assignmentOrder) == Set(VaultColor.palette.map(\.name)))
    }

    @Test("every color keeps the white badge letter at 3:1 contrast or better")
    func whiteLetterContrast() {
        for color in VaultColor.palette {
            let ratio = 1.05 / (Self.luminance(color) + 0.05)
            #expect(ratio >= 3.0, "\(color.name) \(color.hexString): \(ratio)")
        }
    }

    @Test("every color stands apart from the plum rail and from the other colors")
    func colorsAreDistinct() {
        for color in VaultColor.palette {
            #expect(Self.distance(color, Self.rail) >= 0.1, "\(color.name) is too close to the rail")
        }
        let palette = VaultColor.palette
        for i in palette.indices {
            for j in palette.indices where j > i {
                #expect(Self.distance(palette[i], palette[j]) >= 0.045,
                        "\(palette[i].name) and \(palette[j].name) are too alike")
            }
        }
    }

    @Test("components and hex string match the stored value")
    func components() throws {
        let teal = try #require(VaultColor.named("teal"))
        #expect(teal.hexString == "#2A8082")
        #expect(teal.red == Double(0x2A) / 255)
        #expect(teal.green == Double(0x80) / 255)
        #expect(teal.blue == Double(0x82) / 255)
    }

    @Test("named returns nil for a missing, empty or unknown name")
    func namedRejectsUnknown() {
        #expect(VaultColor.named(nil) == nil)
        #expect(VaultColor.named("") == nil)
        #expect(VaultColor.named("chartreuse") == nil)
    }

    // MARK: - Choosing Colors

    @Test("the first vault gets the first color in assignment order")
    func firstVaultColor() {
        #expect(VaultColor.nextForNewVault(among: []).name == VaultColor.assignmentOrder[0])
    }

    @Test("a new vault skips colors that are taken")
    func nextSkipsUsedColors() {
        let order = VaultColor.assignmentOrder
        let existing = [entry("a", color: order[0]), entry("b", color: order[2])]
        #expect(VaultColor.nextForNewVault(among: existing).name == order[1])
    }

    @Test("once every color is taken, the least-used one comes next")
    func nextPrefersLeastUsed() {
        let order = VaultColor.assignmentOrder
        var existing = order.enumerated().map { entry("v\($0.offset)", color: $0.element) }
        existing.append(entry("extra", color: order[0]))
        #expect(VaultColor.nextForNewVault(among: existing).name == order[1])
    }

    @Test("vaults without a color and unknown names don't count as taken")
    func nextIgnoresMissingAndUnknown() {
        let existing = [entry("a"), entry("b", color: ""), entry("c", color: "chartreuse")]
        #expect(VaultColor.nextForNewVault(among: existing).name == VaultColor.assignmentOrder[0])
    }

    @Test("resolved uses the stored color")
    func resolvedUsesStoredColor() {
        #expect(VaultColor.resolved(for: entry("notes", color: "sage")).name == "sage")
    }

    @Test("resolved falls back to the same palette color for the same vault name")
    func resolvedFallbackIsStable() {
        let first = VaultColor.resolved(for: entry("Personal"))
        #expect(VaultColor.named(first.name) != nil)
        #expect(VaultColor.resolved(for: entry("Personal")) == first)
        #expect(VaultColor.resolved(for: entry("Personal", color: "chartreuse")) == first)
        #expect(first == VaultColor.fallback(forVaultNamed: "Personal"))
    }

    // MARK: - Registry

    @Test("addVault gives a vault without a color the next palette color")
    func addVaultAssignsColor() throws {
        var registry = VaultRegistry(primary: "", vaults: [])
        for name in ["one", "two", "three"] {
            try registry.addVault(entry(name))
        }
        let colors = registry.vaults.map(\.color)
        #expect(colors == Array(VaultColor.assignmentOrder.prefix(3)))
    }

    @Test("addVault keeps a color the caller chose")
    func addVaultKeepsExplicitColor() throws {
        var registry = VaultRegistry(primary: "", vaults: [])
        try registry.addVault(entry("mine", color: "berry"))
        #expect(registry.vaults.first?.color == "berry")
    }

    @Test("assignMissingVaultColors fills only missing colors, avoiding ones in use")
    func assignMissingColors() {
        let order = VaultColor.assignmentOrder
        var registry = VaultRegistry(primary: "getting-started", vaults: [
            entry("getting-started"),
            entry("work", color: order[0]),
            entry("future", color: "chartreuse"),
            entry("Personal", color: ""),
        ])

        let firstRun = registry.assignMissingVaultColors()
        #expect(firstRun)
        #expect(registry.vaults.map(\.color) == [order[1], order[0], "chartreuse", order[2]])
        let secondRun = registry.assignMissingVaultColors()
        #expect(!secondRun, "second run has nothing to do")
    }

    // MARK: - VaultStore

    /// A store whose global config, iCloud and local storage all live under `tmpDir`.
    private func makeStore(in tmpDir: String, cloudSync: CloudSyncMode) async throws -> VaultStore {
        let iCloudBase = (tmpDir as NSString).appendingPathComponent("icloud")
        let store = VaultStore(
            globalConfigDir: tmpDir,
            iCloudDocumentsBase: iCloudBase,
            localStorageBase: (tmpDir as NSString).appendingPathComponent("local"))
        try await store.setCloudSyncMode(cloudSync)
        try FileManager.default.createDirectory(
            atPath: (iCloudBase as NSString).appendingPathComponent("config"), withIntermediateDirectories: true)
        return store
    }

    private func makeTempDir() throws -> String {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-color-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp.path
    }

    @Test("VaultStore.assignMissingVaultColors saves once, for both registry locations",
          arguments: [CloudSyncMode.off, .icloud])
    func storeAssignsAndSaves(cloudSync: CloudSyncMode) async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        let store = try await makeStore(in: tmpDir, cloudSync: cloudSync)
        try await store.saveRegistry(VaultRegistry(primary: "Personal", vaults: [
            entry("getting-started"), entry("Personal"),
        ]))

        #expect(try await store.assignMissingVaultColors())
        let saved = try #require(try await store.loadRegistry())
        #expect(saved.vaults.map(\.color) == Array(VaultColor.assignmentOrder.prefix(2)))
        #expect(saved.primary == "Personal")
        #expect(try await !store.assignMissingVaultColors(), "second run has nothing to do")
    }

    @Test("VaultStore.assignMissingVaultColors leaves an undownloaded iCloud registry alone")
    func storeSkipsUnavailableICloudRegistry() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        let store = try await makeStore(in: tmpDir, cloudSync: .icloud)
        let config = (tmpDir as NSString).appendingPathComponent("icloud/config")
        try Data().write(to: URL(fileURLWithPath: (config as NSString).appendingPathComponent(".vaults.yaml.icloud")))

        await #expect(throws: (any Error).self) { try await store.assignMissingVaultColors() }
        #expect(!FileManager.default.fileExists(atPath: (config as NSString).appendingPathComponent("vaults.yaml")))
    }

    @Test("VaultStore.assignMissingVaultColors never turns the cache into the iCloud registry")
    func storeIgnoresCacheWhenICloudRegistryMissing() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        let store = try await makeStore(in: tmpDir, cloudSync: .icloud)
        try await store.saveCachedRegistry(VaultRegistry(primary: "Personal", vaults: [entry("Personal")]))

        #expect(try await !store.assignMissingVaultColors())
        let registryPath = (tmpDir as NSString).appendingPathComponent("icloud/config/vaults.yaml")
        #expect(!FileManager.default.fileExists(atPath: registryPath))
        #expect(try await store.loadCachedRegistry()?.vaults.first?.color == nil, "cache is left as it was")
    }
}
