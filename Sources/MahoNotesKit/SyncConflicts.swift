import Foundation

// MARK: - Conflict copies

/// True for a conflict copy left by sync: `note.conflict-{DeviceName}.md`, or the
/// `note.conflict-{timestamp}-local.md` form before the app renames it.
///
/// A conflict copy holds this device's version of a file whose other version won; it is
/// never synced itself, and stays until the user merges it by hand and deletes it.
public func isConflictCopyPath(_ path: String) -> Bool {
    (path as NSString).lastPathComponent.contains(".conflict-")
}

/// Lines both sync paths keep in a vault's `.gitignore`: device-local state, the generated
/// site, and conflict copies — which hold one device's version and are resolved on that
/// device, so they are not pushed (the REST path never uploads them either).
let syncGitignoreEntries = [".maho/", "_site/", "*.conflict-*"]

/// Conflict copies currently in a vault, as paths relative to the vault root, sorted.
/// Includes copies left by earlier syncs — the ones still waiting to be resolved.
public func conflictCopies(inVault vaultPath: String) -> [String] {
    let baseURL = URL(fileURLWithPath: vaultPath).standardizedFileURL
    guard let enumerator = FileManager.default.enumerator(
        at: baseURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsPackageDescendants]
    ) else { return [] }

    let basePath = baseURL.path
    var found: [String] = []
    for case let fileURL as URL in enumerator {
        let name = fileURL.lastPathComponent
        if name == ".git" || name == ".maho" || name == "_site" {
            enumerator.skipDescendants()
            continue
        }
        guard name.contains(".conflict-"),
              (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        else { continue }
        let fullPath = fileURL.standardizedFileURL.path
        if fullPath.hasPrefix(basePath + "/") {
            found.append(String(fullPath.dropFirst(basePath.count + 1)))
        }
    }
    return found.sorted()
}

// MARK: - Collection index merge

/// Three-way merge for a collection's `_index.md`.
///
/// `_index.md` is structured metadata — a title and other fields, the note order (`order:`),
/// the sub-collection order (`children:`) — not prose. Two devices that each add a note to
/// the same collection both change the same few lines, which a line-based merge reports as a
/// conflict even though the two changes are independent. This merges by meaning instead:
///
/// - Fields other than the two lists, and the body, merge per field: a field only one side
///   changed takes that side's value; a field both changed differently is a conflict.
/// - A list merges per entry against the common base. An entry one side removed stays
///   removed (the two lists are never simply united — that would bring back a note the
///   other device deleted). Entries either side added are kept, each after the entry it
///   followed on the side that added it. A reorder by one side is kept; different reorders
///   by both sides are a conflict.
///
/// Anything it cannot decide is reported as a conflict, for the caller to handle like any
/// other conflicting file (keep both versions, let the user choose).
public enum CollectionIndexMerge {

    public enum Outcome: Equatable, Sendable {
        /// The merged file content.
        case merged(String)
        /// The two versions contradict each other; the reason is for logs and messages.
        case conflict(String)
    }

    /// Whether `path` is a collection index (`_index.md`, at any depth).
    public static func isCollectionIndex(path: String) -> Bool {
        (path as NSString).lastPathComponent == "_index.md"
    }

    private static let listKeys = ["order", "children"]

    /// Merge `local` and `remote`, both derived from `base`.
    ///
    /// - Parameter base: The last version both sides had, or nil when there is none (the file
    ///   was created independently on both sides). Without a base only versions that already
    ///   agree can be merged: there is no telling an addition from a removal.
    public static func merge(base: String?, local: String, remote: String) -> Outcome {
        if local == remote { return .merged(local) }
        if let base {
            if base == local { return .merged(remote) }
            if base == remote { return .merged(local) }
        }

        let localDoc = FrontmatterDocument(local)
        let remoteDoc = FrontmatterDocument(remote)
        guard let localYAML = try? localDoc.yaml(), let remoteYAML = try? remoteDoc.yaml() else {
            return .conflict("frontmatter is not valid YAML")
        }
        guard let base else {
            return .conflict("no common base version")
        }
        let baseDoc = FrontmatterDocument(base)
        guard let baseYAML = try? baseDoc.yaml() else {
            return .conflict("base frontmatter is not valid YAML")
        }

        var merged = localDoc
        var expected = localYAML

        // Fields other than the lists.
        let scalarKeys = Set(baseYAML.keys).union(localYAML.keys).union(remoteYAML.keys)
            .subtracting(listKeys)
        for key in scalarKeys.sorted() {
            let b = baseYAML[key], l = localYAML[key], r = remoteYAML[key]
            if same(l, r) || same(r, b) { continue }          // nothing to take from remote
            guard same(l, b) else {
                return .conflict("`\(key)` was changed on both sides")
            }
            if r == nil {
                merged.remove(key)
                expected[key] = nil
            } else if let block = remoteDoc.rawBlock(of: key) {
                merged.setBlock(key, rawLines: block)
                expected[key] = r
            } else {
                // Present in the parsed YAML but not as a top-level line (a flow mapping).
                return .conflict("`\(key)` cannot be merged in place")
            }
        }

        // The two lists.
        for key in listKeys {
            let b = strings(baseYAML[key]), l = strings(localYAML[key]), r = strings(remoteYAML[key])
            guard let list = mergeList(base: b, local: l, remote: r) else {
                return .conflict("`\(key)` was reordered differently on both sides")
            }
            guard list != l else { continue }
            if list.isEmpty {
                merged.remove(key)
            } else {
                merged.set(key, blockList: list)
            }
            expected[key] = list.isEmpty ? nil : list
        }

        // Body.
        if localDoc.body != remoteDoc.body, remoteDoc.body != baseDoc.body {
            guard localDoc.body == baseDoc.body else {
                return .conflict("the description text was changed on both sides")
            }
            merged.body = remoteDoc.body
        }

        // Frontmatter the line editor cannot edit in place (a flow mapping, an indented
        // mapping) would come out wrong. Check the result says what was intended.
        guard let result = try? merged.yaml(),
              Set(result.keys) == Set(expected.keys),
              result.allSatisfy({ same($0.value, expected[$0.key]) })
        else {
            return .conflict("the merged frontmatter did not read back as intended")
        }
        return .merged(merged.rendered())
    }

    /// Three-way merge of an ordered list of names. Nil when both sides reordered the
    /// entries they share, in different ways.
    static func mergeList(base: [String], local: [String], remote: [String]) -> [String]? {
        let base = unique(base), local = unique(local), remote = unique(remote)
        if local == remote { return local }
        if local == base { return remote }
        if remote == base { return local }

        let baseSet = Set(base), localSet = Set(local), remoteSet = Set(remote)
        // Entries all three have: their relative order shows who reordered.
        let shared = baseSet.intersection(localSet).intersection(remoteSet)
        let baseOrder = base.filter(shared.contains)
        let localOrder = local.filter(shared.contains)
        let remoteOrder = remote.filter(shared.contains)
        let localReordered = localOrder != baseOrder
        let remoteReordered = remoteOrder != baseOrder
        if localReordered, remoteReordered, localOrder != remoteOrder { return nil }

        // Start from the entries both sides kept, in the order of whichever side moved them.
        var result = localReordered ? localOrder : remoteOrder

        // Then each side's additions, placed after the entry they followed on that side
        // (local first, so its additions come before remote's where both follow the same entry).
        var placed = Set(result)
        for (side, sideSet, otherSet) in [(local, localSet, remoteSet), (remote, remoteSet, localSet)] {
            var anchor: String?          // the last entry of `side` already in the result
            for name in side {
                if placed.contains(name) {
                    anchor = name
                    continue
                }
                // In base but gone from the other side: that side removed it. It stays removed.
                if baseSet.contains(name), !otherSet.contains(name) { continue }
                var index = anchor.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
                // Step over what the other side already put after the same entry.
                while index < result.count, !sideSet.contains(result[index]) { index += 1 }
                result.insert(name, at: index)
                placed.insert(name)
                anchor = name
            }
        }
        return result
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    private static func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.map { $0 as? String ?? "\($0)" } ?? []
    }

    /// Whether two parsed YAML values are the same (both absent counts as the same).
    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return (a as AnyObject).isEqual(b as AnyObject)
        default: return false
        }
    }
}
