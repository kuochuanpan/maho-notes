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

    let (yamlStr, _) = splitFrontmatter(content)
    guard let yamlStr,
          let yaml = try? Yams.load(yaml: yamlStr) as? [String: Any] else {
        return ([], [])
    }

    let notes = yaml["order"] as? [String] ?? []
    let children = yaml["children"] as? [String] ?? []
    return (notes, children)
}

/// Write the `order:` and/or `children:` fields to a directory's `_index.md` frontmatter.
/// Creates `_index.md` if it doesn't exist. Preserves existing frontmatter fields.
public func writeDirectoryOrder(at directoryPath: String, notes: [String]? = nil, children: [String]? = nil) throws {
    let indexPath = (directoryPath as NSString).appendingPathComponent("_index.md")
    let fm = FileManager.default

    var yaml: [String: Any] = [:]
    var body = ""

    if fm.fileExists(atPath: indexPath),
       let content = try? String(contentsOfFile: indexPath, encoding: .utf8) {
        let (yamlStr, bodyStr) = splitFrontmatter(content)
        body = bodyStr
        if let yamlStr,
           let parsed = try? Yams.load(yaml: yamlStr) as? [String: Any] {
            yaml = parsed
        }
    }

    if let notes {
        if notes.isEmpty {
            yaml.removeValue(forKey: "order")
        } else {
            yaml["order"] = notes
        }
    }
    if let children {
        if children.isEmpty {
            yaml.removeValue(forKey: "children")
        } else {
            yaml["children"] = children
        }
    }

    // Build output manually to control field order (title first, then order, then children, then rest)
    var lines: [String] = []
    if let title = yaml["title"] as? String {
        lines.append("title: \(title)")
    }
    if let description = yaml["description"] as? String {
        lines.append("description: \(description)")
    }
    if let order = yaml["order"] as? [String], !order.isEmpty {
        lines.append("order:")
        for item in order {
            lines.append("  - \(item)")
        }
    }
    if let childrenList = yaml["children"] as? [String], !childrenList.isEmpty {
        lines.append("children:")
        for item in childrenList {
            lines.append("  - \(item)")
        }
    }
    // Append any other fields we didn't handle
    let handledKeys: Set<String> = ["title", "description", "order", "children"]
    for (key, value) in yaml where !handledKeys.contains(key) {
        let yamlValue = try Yams.dump(object: [key: value])
        // Yams.dump adds trailing newline — strip it
        lines.append(yamlValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    let frontmatter = lines.joined(separator: "\n")
    let output = "---\n\(frontmatter)\n---\(body)"
    try output.write(toFile: indexPath, atomically: true, encoding: .utf8)
}

/// Sort items according to an order list. Listed items come first in order,
/// unlisted items are appended alphabetically.
public func sortByOrder<T>(_ items: [T], order: [String], keyPath: (T) -> String) -> [T] {
    guard !order.isEmpty else { return items }
    let orderIndex = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
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
