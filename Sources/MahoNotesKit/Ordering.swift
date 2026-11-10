import Foundation
import Yams

/// Read the `order:` and `children:` fields from a directory's `_index.md` frontmatter.
/// Returns empty arrays if `_index.md` doesn't exist or lacks those fields.
public func readDirectoryOrder(at directoryPath: String) -> (notes: [String], children: [String]) {
    let indexPath = (directoryPath as NSString).appendingPathComponent("_index.md")
    guard FileManager.default.fileExists(atPath: indexPath),
          let content = try? String(contentsOfFile: indexPath, encoding: .utf8) else {
        return ([], [])
    }

    let document = FrontmatterDocument(content)
    guard document.hasFrontmatter else { return ([], []) }
    if let yaml = try? document.yaml() {
        return (stringList(yaml["order"]), stringList(yaml["children"]))
    }

    // The frontmatter as a whole is not valid YAML (an old `title: Plans: 2026`, say).
    // The two lists are usually still fine on their own, so read each by itself rather
    // than report an empty order that the next write would then make permanent.
    func list(_ key: String) -> [String] {
        guard let block = document.rawBlock(of: key),
              let yaml = try? Yams.load(yaml: block.joined(separator: "\n")) as? [String: Any]
        else { return [] }
        return stringList(yaml[key])
    }
    return (list("order"), list("children"))
}

private func stringList(_ value: Any?) -> [String] {
    (value as? [Any])?.map { $0 as? String ?? "\($0)" } ?? []
}

/// Write the `order:` and/or `children:` fields to a directory's `_index.md` frontmatter.
/// Creates `_index.md` if it doesn't exist.
///
/// Only the lines of the list being written change. Every other field, comment and the
/// body stay byte-for-byte as they were — including fields that are not valid YAML, which
/// a parse-and-dump rewrite would silently drop.
public func writeDirectoryOrder(at directoryPath: String, notes: [String]? = nil, children: [String]? = nil) throws {
    let indexPath = (directoryPath as NSString).appendingPathComponent("_index.md")
    let existing = try? String(contentsOfFile: indexPath, encoding: .utf8)
    var document = FrontmatterDocument(existing ?? "")

    func apply(_ key: String, _ items: [String]?) {
        guard let items else { return }
        // Listing a name twice would make it ambiguous which position counts.
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0).inserted }
        if unique.isEmpty {
            document.remove(key)
        } else {
            document.set(key, blockList: unique)
        }
    }
    apply("order", notes)
    apply("children", children)

    // Nothing to record and no file yet: don't create an empty one.
    if existing == nil, !document.hasFrontmatter { return }

    // Frontmatter the line editor can't edit in place — a flow mapping `{title: T, order: […]}`,
    // an indented mapping — would come out invalid or with the old list still winning. When the
    // original was readable and the edit doesn't read back as intended, regenerate from the
    // parsed values instead.
    let original = FrontmatterDocument(existing ?? "")
    if let before = try? original.yaml() {
        var expected = before
        func expect(_ key: String, _ items: [String]?) {
            guard let items else { return }
            var seen = Set<String>()
            let unique = items.filter { seen.insert($0).inserted }
            expected[key] = unique.isEmpty ? nil : unique
        }
        expect("order", notes)
        expect("children", children)

        let after = try? document.yaml()
        let matches = after.map {
            stringList($0["order"]) == stringList(expected["order"])
                && stringList($0["children"]) == stringList(expected["children"])
                && Set($0.keys) == Set(expected.keys)
        } ?? false
        if !matches {
            let dumped = try Yams.dump(object: expected, sortKeys: true)
            let separator = original.body.isEmpty ? "" : original.body
            try "---\n\(dumped)---\n\(separator)".write(toFile: indexPath, atomically: true, encoding: .utf8)
            return
        }
    }
    try document.rendered().write(toFile: indexPath, atomically: true, encoding: .utf8)
}

/// Sort items according to an order list. Listed items come first in order,
/// unlisted items are appended alphabetically.
public func sortByOrder<T>(_ items: [T], order: [String], keyPath: (T) -> String) -> [T] {
    guard !order.isEmpty else { return items }
    // The first position wins if a name is listed twice (`uniqueKeysWithValues` would trap).
    let orderIndex = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    let (listed, unlisted) = items.reduce(into: ([(Int, T)](), [T]())) { result, item in
        let key = keyPath(item)
        if let idx = orderIndex[key] {
            result.0.append((idx, item))
        } else {
            result.1.append(item)
        }
    }
    let sortedListed = listed.sorted { $0.0 < $1.0 }.map { $0.1 }
    let sortedUnlisted = unlisted.sorted { keyPath($0).localizedStandardCompare(keyPath($1)) == .orderedAscending }
    return sortedListed + sortedUnlisted
}
