import Foundation
import Yams

// Finds vaults, collections and notes that exist on disk but don't show up in Maho Notes,
// and fixes them on request. Nothing here deletes files: fixes register vaults, add
// collections to maho.yaml, create folders, move or rename notes, re-encode text, or ask
// iCloud to download.

// MARK: - Unregistered vaults

/// A vault folder in iCloud or this device's storage that isn't in the vault registry.
public struct FoundVault: Sendable, Hashable, Codable, Identifiable {
    public var id: String { path }
    /// Folder name. Vault paths are derived from the name, so this is also the vault name.
    public let name: String
    /// Absolute path of the folder.
    public let path: String
    /// Type the vault gets when added: `.icloud` for a folder in iCloud, `.github` when its
    /// `maho.yaml` names a repo, `.device` otherwise.
    public let type: VaultType
    /// `owner/repo` from `maho.yaml` `github.repo`.
    public let github: String?
    /// `maho.yaml` `title`, used as the display name.
    public let title: String?
    public let noteCount: Int
    /// Most recent modification of any note in the vault.
    public let lastModified: Date?
}

/// Lists vault folders under `<iCloudBase>/vaults/` (only when `includeICloud`) and
/// `<localBase>/vaults/` that aren't registered. A folder counts as a vault when it has a
/// `maho.yaml`, downloaded or not.
///
/// A folder whose name is already registered is skipped: names are unique, and such a
/// folder is usually the copy a device ↔ iCloud migration leaves behind. For the same
/// reason, when iCloud and local storage both hold an unregistered folder of one name,
/// only the iCloud one is reported.
func findUnregisteredVaults(
    registry: VaultRegistry,
    iCloudBase: String,
    localBase: String,
    includeICloud: Bool
) -> [FoundVault] {
    let taken = Set(registry.vaults.map { $0.name.lowercased() })
    var found: [FoundVault] = []
    var seen: Set<String> = []

    let locations: [(base: String, isICloud: Bool)] =
        (includeICloud ? [(iCloudBase, true)] : []) + [(localBase, false)]

    for location in locations {
        let vaultsDir = (location.base as NSString).appendingPathComponent("vaults")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: vaultsDir) else { continue }

        for name in names.sorted() where !name.hasPrefix(".") {
            let key = name.lowercased()
            guard !taken.contains(key), !seen.contains(key) else { continue }

            let path = (vaultsDir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }

            let configPath = (path as NSString).appendingPathComponent("maho.yaml")
            guard iCloudFileExists(atPath: configPath) else { continue }

            let config = (try? String(contentsOfFile: configPath, encoding: .utf8))
                .flatMap { try? Yams.load(yaml: $0) as? [String: Any] } ?? [:]
            let repo = ((config["github"] as? [String: Any])?["repo"] as? String)
                .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            let title = (config["title"] as? String)
                .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }

            let type: VaultType = location.isICloud ? .icloud : (repo != nil ? .github : .device)
            let stats = noteStats(in: path)
            found.append(FoundVault(
                name: name,
                path: path,
                type: type,
                github: repo,
                title: title,
                noteCount: stats.count,
                lastModified: stats.lastModified
            ))
            seen.insert(key)
        }
    }
    return found
}

/// Counts notes (including ones iCloud hasn't downloaded) and finds the latest edit.
private func noteStats(in vaultPath: String) -> (count: Int, lastModified: Date?) {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
        at: URL(fileURLWithPath: vaultPath),
        includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
    ) else { return (0, nil) }

    var count = 0
    var latest: Date?
    for case let url as URL in enumerator {
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
        if values?.isDirectory == true {
            if name.hasPrefix(".") { enumerator.skipDescendants() }
            continue
        }
        let noteName = name.hasPrefix(".") && name.hasSuffix(".icloud")
            ? String(name.dropFirst().dropLast(".icloud".count))
            : name
        guard !noteName.hasPrefix("."), (noteName as NSString).pathExtension == "md",
              noteName != "_index.md", noteName.lowercased() != "readme.md"
        else { continue }
        count += 1
        if noteName == name, let date = values?.contentModificationDate, date > (latest ?? .distantPast) {
            latest = date
        }
    }
    return (count, latest)
}

// MARK: - Reports

/// What `VaultStore.findMissingItems()` found.
public struct MissingItemsReport: Sendable, Codable {
    public let unregisteredVaults: [FoundVault]
    /// Registered vaults with at least one issue.
    public let vaults: [VaultIssueReport]

    public var isEmpty: Bool { unregisteredVaults.isEmpty && vaults.isEmpty }
}

/// The issues found in one registered vault.
public struct VaultIssueReport: Sendable, Codable, Identifiable {
    public var id: String { vaultName }
    public let vaultName: String
    public let displayName: String?
    public let vaultPath: String
    public let issues: [VaultIssue]
}

// MARK: - Vault content

/// Something in a vault that Maho Notes doesn't show, or that its `maho.yaml` is missing.
public struct VaultIssue: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// `maho.yaml` exists but can't be parsed. Collections weren't checked.
        case unreadableConfig
        /// `maho.yaml` is an iCloud placeholder. Collections weren't checked.
        case configNotDownloaded
        /// A top-level folder with notes that `maho.yaml` doesn't list. It's shown last,
        /// with a default icon, and can't be reordered.
        case unlistedCollection
        /// `maho.yaml` lists a collection whose folder doesn't exist, so it isn't shown.
        case collectionFolderMissing
        /// A note at the vault root. Notes are only shown inside collections.
        case noteOutsideCollections
        /// A Markdown file whose extension isn't exactly `.md` (`.markdown`, `.MD`, …).
        case nonStandardExtension
        /// A `.md` file that isn't UTF-8 text, so it isn't shown.
        case notUTF8
        /// A note iCloud hasn't downloaded to this device yet.
        case notDownloaded
    }

    public let kind: Kind
    /// Path relative to the vault root: the collection id for collection issues, the file
    /// for note issues, `maho.yaml` for config issues.
    public let path: String
    /// Collection display name, or the parse error for `unreadableConfig`.
    public let detail: String?
    /// Whether `Vault.fix(_:)` can resolve it.
    public let isFixable: Bool

    public var id: String { "\(kind.rawValue):\(path)" }

    public init(kind: Kind, path: String, detail: String? = nil, isFixable: Bool) {
        self.kind = kind
        self.path = path
        self.detail = detail
        self.isFixable = isFixable
    }
}

public enum VaultScanError: Error, LocalizedError {
    case notFixable(VaultIssue.Kind)
    case configNotEditable(String)
    case notConvertible(String)

    public var errorDescription: String? {
        switch self {
        case .notFixable(let kind): return "'\(kind.rawValue)' can't be fixed automatically."
        case .configNotEditable(let reason): return "maho.yaml can't be updated: \(reason)"
        case .notConvertible(let path): return "\(path) isn't UTF-16 or UTF-32 text with a byte order mark."
        }
    }
}

extension Vault {
    /// Folder that notes outside any collection are moved into.
    public static let unsortedCollectionId = "unsorted"

    /// Markdown extensions other than `.md`. The app only lists `.md` files.
    private static let otherMarkdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn"]

    /// Repository documents that sit at a vault root on purpose and aren't notes.
    private static let repoDocuments: Set<String> = [
        "readme", "license", "changelog", "contributing", "code_of_conduct", "security",
    ]

    /// Finds collections missing from `maho.yaml` or from disk, and notes the app can't
    /// show. Reads the vault without changing anything.
    public func findIssues() -> [VaultIssue] {
        var issues: [VaultIssue] = []

        switch configState() {
        case .listed(let listed):
            issues += collectionIssues(listed: listed)
        case .notDownloaded:
            issues.append(VaultIssue(kind: .configNotDownloaded, path: "maho.yaml", isFixable: true))
        case .unreadable(let message):
            issues.append(VaultIssue(kind: .unreadableConfig, path: "maho.yaml", detail: message, isFixable: false))
        }

        issues += noteIssues()
        return issues
    }

    /// Applies the fix for one issue.
    /// - Parameter unsortedCollectionName: Display name for the collection notes outside any
    ///   collection are moved into, if it has to be created.
    public func fix(_ issue: VaultIssue, unsortedCollectionName: String = "Unsorted") throws {
        let fm = FileManager.default
        let target = (path as NSString).appendingPathComponent(issue.path)

        switch issue.kind {
        case .configNotDownloaded, .notDownloaded:
            try fm.startDownloadingUbiquitousItem(at: URL(fileURLWithPath: target))

        case .unlistedCollection:
            try requireEditableConfig()
            try addCollection(vaultPath: path, id: issue.path, name: issue.detail ?? issue.path)

        case .collectionFolderMissing:
            try fm.createDirectory(atPath: target, withIntermediateDirectories: true)

        case .noteOutsideCollections:
            try ensureUnsortedCollection(named: unsortedCollectionName)
            _ = try moveNote(relativePath: issue.path, toCollection: Self.unsortedCollectionId)

        case .nonStandardExtension:
            let dir = (target as NSString).deletingLastPathComponent
            let base = ((target as NSString).lastPathComponent as NSString).deletingPathExtension
            var dest = (dir as NSString).appendingPathComponent("\(base).md")
            var counter = 1
            while fm.fileExists(atPath: dest) && !Self.isSameFile(dest, target) {
                dest = (dir as NSString).appendingPathComponent("\(base)-\(counter).md")
                counter += 1
            }
            if Self.isSameFile(dest, target) {
                // Case-only rename (note.MD → note.md) on a case-insensitive volume: the
                // destination "exists" because it is this file, so go through a temp name.
                let temp = (dir as NSString).appendingPathComponent(".\(UUID().uuidString).md")
                try fm.moveItem(atPath: target, toPath: temp)
                do {
                    try fm.moveItem(atPath: temp, toPath: dest)
                } catch {
                    try? fm.moveItem(atPath: temp, toPath: target)
                    throw error
                }
            } else {
                try fm.moveItem(atPath: target, toPath: dest)
            }

        case .notUTF8:
            let data = try Data(contentsOf: URL(fileURLWithPath: target))
            guard let (encoding, bomLength) = Self.unicodeEncoding(ofBOM: data),
                  let text = String(data: data.dropFirst(bomLength), encoding: encoding)
            else { throw VaultScanError.notConvertible(issue.path) }
            try text.write(toFile: target, atomically: true, encoding: .utf8)

        case .unreadableConfig:
            throw VaultScanError.notFixable(issue.kind)
        }
    }

    /// Applies fixes in a safe order (downloads, then collections, then notes) and returns
    /// the ones that failed. Issues that aren't fixable are skipped.
    public func fix(
        _ issues: [VaultIssue],
        unsortedCollectionName: String = "Unsorted"
    ) -> [(issue: VaultIssue, error: any Error)] {
        let order: [VaultIssue.Kind] = [
            .configNotDownloaded, .notDownloaded, .unlistedCollection, .collectionFolderMissing,
            .nonStandardExtension, .notUTF8, .noteOutsideCollections,
        ]
        var failures: [(issue: VaultIssue, error: any Error)] = []
        for kind in order {
            for issue in issues where issue.kind == kind && issue.isFixable {
                do {
                    try fix(issue, unsortedCollectionName: unsortedCollectionName)
                } catch {
                    failures.append((issue, error))
                }
            }
        }
        return failures
    }

    // MARK: Config

    private enum ConfigState {
        /// Collection ids and names listed in maho.yaml (empty when there's no maho.yaml).
        case listed([(id: String, name: String)])
        case notDownloaded
        case unreadable(String)
    }

    /// Reads maho.yaml without side effects (`loadCollections` may migrate collections.yaml).
    private func configState() -> ConfigState {
        let fm = FileManager.default
        let configPath = (path as NSString).appendingPathComponent("maho.yaml")
        guard fm.fileExists(atPath: configPath) else {
            return fm.fileExists(atPath: iCloudPlaceholderPath(for: configPath)) ? .notDownloaded : .listed([])
        }
        do {
            let content = try String(contentsOfFile: configPath, encoding: .utf8)
            guard let loaded = try Yams.load(yaml: content) else { return .listed([]) }
            guard let yaml = loaded as? [String: Any] else {
                return .unreadable("the top level isn't a key–value mapping")
            }
            guard let rawCollections = yaml["collections"] else { return .listed([]) }
            guard let items = rawCollections as? [[String: Any]] else {
                return .unreadable("collections isn't a list")
            }
            return .listed(items.compactMap { item in
                guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
                return (id, name)
            })
        } catch {
            let message = String(describing: error).components(separatedBy: "\n").first ?? "\(error)"
            return .unreadable(message)
        }
    }

    /// Throws unless maho.yaml is absent or parses as a mapping. `addCollection` treats an
    /// unreadable maho.yaml as empty and would overwrite it.
    private func requireEditableConfig() throws {
        switch configState() {
        case .listed: return
        case .notDownloaded: throw VaultScanError.configNotEditable("it hasn't downloaded from iCloud yet")
        case .unreadable(let message): throw VaultScanError.configNotEditable(message)
        }
    }

    private func ensureUnsortedCollection(named name: String) throws {
        try requireEditableConfig()
        guard case .listed(let listed) = configState() else { return }
        let id = Self.unsortedCollectionId
        if listed.contains(where: { $0.id == id }) {
            let dir = (path as NSString).appendingPathComponent(id)
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } else {
            try addCollection(vaultPath: path, id: id, name: name, icon: "tray")
        }
    }

    // MARK: Collections

    private func collectionIssues(listed: [(id: String, name: String)]) -> [VaultIssue] {
        let fm = FileManager.default
        var issues: [VaultIssue] = []
        let listedIds = Set(listed.map(\.id))

        let folders = ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { name in
            var isDir: ObjCBool = false
            let full = (path as NSString).appendingPathComponent(name)
            return !name.hasPrefix(".") && !name.hasPrefix("_")
                && fm.fileExists(atPath: full, isDirectory: &isDir) && isDir.boolValue
        }

        for folder in folders.sorted() where !listedIds.contains(folder) {
            let full = (path as NSString).appendingPathComponent(folder)
            // Folders without notes (assets, scripts, …) aren't collections
            guard noteStats(in: full).count > 0 else { continue }
            issues.append(VaultIssue(
                kind: .unlistedCollection, path: folder,
                detail: indexTitle(ofFolder: full) ?? folder, isFixable: true))
        }

        for item in listed where Self.isPlainFolderName(item.id) {
            let full = (path as NSString).appendingPathComponent(item.id)
            if !fm.fileExists(atPath: full) {
                issues.append(VaultIssue(
                    kind: .collectionFolderMissing, path: item.id, detail: item.name, isFixable: true))
            }
        }
        return issues
    }

    /// A name that's safe to create as a folder directly under the vault root.
    private static func isPlainFolderName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.hasPrefix(".") && !name.hasPrefix("_")
    }

    private func indexTitle(ofFolder folder: String) -> String? {
        let indexPath = (folder as NSString).appendingPathComponent("_index.md")
        guard let content = try? String(contentsOfFile: indexPath, encoding: .utf8),
              let yamlStr = splitFrontmatter(content).yaml,
              let yaml = try? Yams.load(yaml: yamlStr) as? [String: Any]
        else { return nil }
        return yaml["title"] as? String
    }

    // MARK: Notes

    private func noteIssues() -> [VaultIssue] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }

        var issues: [VaultIssue] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                // `.maho`, `.git`, `_assets`, … hold no notes the app would show
                if name.hasPrefix(".") || name.hasPrefix("_") { enumerator.skipDescendants() }
                continue
            }

            var absolute = url.path
            if !absolute.hasPrefix(prefix) { absolute = url.resolvingSymlinksInPath().path }
            guard absolute.hasPrefix(prefix) else { continue }
            let relative = String(absolute.dropFirst(prefix.count))
            let dir = (relative as NSString).deletingLastPathComponent

            if name.hasPrefix(".") {
                // iCloud placeholder for a file this device hasn't downloaded: ".note.md.icloud"
                guard name.hasSuffix(".icloud") else { continue }
                let realName = String(name.dropFirst().dropLast(".icloud".count))
                guard (realName as NSString).pathExtension.lowercased() == "md",
                      !Self.isNotANote(realName, atVaultRoot: dir.isEmpty) else { continue }
                issues.append(VaultIssue(
                    kind: .notDownloaded, path: (dir as NSString).appendingPathComponent(realName), isFixable: true))
                continue
            }

            guard !Self.isNotANote(name, atVaultRoot: dir.isEmpty) else { continue }
            let ext = (name as NSString).pathExtension
            if ext != "md" {
                if Self.otherMarkdownExtensions.contains(ext.lowercased()) {
                    issues.append(VaultIssue(kind: .nonStandardExtension, path: relative, isFixable: true))
                }
                continue
            }
            guard name != "_index.md" else { continue }

            if dir.isEmpty {
                issues.append(VaultIssue(kind: .noteOutsideCollections, path: relative, isFixable: true))
            }
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe),
               String(data: data, encoding: .utf8) == nil {
                issues.append(VaultIssue(
                    kind: .notUTF8, path: relative, isFixable: Self.unicodeEncoding(ofBOM: data) != nil))
            }
        }
        return issues.sorted { ($0.path, $0.kind.rawValue) < ($1.path, $1.kind.rawValue) }
    }

    /// READMEs are repository docs the app never lists, wherever they are. LICENSE,
    /// CHANGELOG, … are only treated as repo docs at the vault root.
    private static func isNotANote(_ fileName: String, atVaultRoot: Bool) -> Bool {
        let base = (fileName as NSString).deletingPathExtension.lowercased()
        return base == "readme" || (atVaultRoot && repoDocuments.contains(base))
    }

    /// Whether two paths name the same file (true for `a.MD` / `a.md` on a case-insensitive volume).
    private static func isSameFile(_ a: String, _ b: String) -> Bool {
        let fm = FileManager.default
        guard let lhs = try? fm.attributesOfItem(atPath: a), let rhs = try? fm.attributesOfItem(atPath: b),
              let lhsNumber = lhs[.systemFileNumber] as? UInt64, let rhsNumber = rhs[.systemFileNumber] as? UInt64
        else { return false }
        return lhsNumber == rhsNumber && (lhs[.systemNumber] as? Int) == (rhs[.systemNumber] as? Int)
    }

    /// Detects UTF-16/UTF-32 from a byte order mark: the only non-UTF-8 text that can be
    /// converted without guessing the encoding.
    static func unicodeEncoding(ofBOM data: Data) -> (String.Encoding, Int)? {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return (.utf32LittleEndian, 4) }
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return (.utf32BigEndian, 4) }
        if bytes.starts(with: [0xFF, 0xFE]) { return (.utf16LittleEndian, 2) }
        if bytes.starts(with: [0xFE, 0xFF]) { return (.utf16BigEndian, 2) }
        return nil
    }
}
