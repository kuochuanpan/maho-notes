import Foundation
import Yams

/// Splits a markdown file into (YAML frontmatter string, body content).
/// Returns nil for frontmatter if no valid `---` delimiters are found.
public func splitFrontmatter(_ content: String) -> (yaml: String?, body: String) {
    guard content.hasPrefix("---") else {
        return (nil, content)
    }

    let lines = content.components(separatedBy: "\n")
    // Find closing ---
    var closingIndex: Int?
    for i in 1..<lines.count {
        if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            closingIndex = i
            break
        }
    }

    guard let endIdx = closingIndex else {
        return (nil, content)
    }

    let yamlLines = lines[1..<endIdx]
    let yamlStr = yamlLines.joined(separator: "\n")
    let bodyLines = lines[(endIdx + 1)...]
    let body = bodyLines.joined(separator: "\n")

    return (yamlStr, body)
}

private func formatDateField(_ value: Any?) -> String {
    guard let value else { return "" }
    if let date = value as? Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
    return "\(value)"
}

/// Parses a markdown file at the given path into a Note
public func parseNote(at filePath: String, relativeTo vaultPath: String) throws -> Note? {
    let content = try String(contentsOfFile: filePath, encoding: .utf8)
    let (yamlStr, body) = splitFrontmatter(content)

    guard let yamlStr,
          let yaml = try Yams.load(yaml: yamlStr) as? [String: Any]
    else {
        return nil
    }

    guard let title = yaml["title"] as? String else {
        return nil
    }

    let tags: [String]
    if let tagArray = yaml["tags"] as? [String] {
        tags = tagArray
    } else if let tagStr = yaml["tags"] as? String {
        tags = tagStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    } else {
        tags = []
    }

    // Compute relative path from vault root
    let vaultURL = URL(fileURLWithPath: vaultPath).standardizedFileURL
    let fileURL = URL(fileURLWithPath: filePath).standardizedFileURL
    let relPath = fileURL.path.replacingOccurrences(of: vaultURL.path + "/", with: "")

    return Note(
        relativePath: relPath,
        title: title,
        tags: tags,
        created: formatDateField(yaml["created"]),
        updated: formatDateField(yaml["updated"]),
        isPublic: yaml["public"] as? Bool ?? false,
        slug: yaml["slug"] as? String,
        author: yaml["author"] as? String,
        draft: yaml["draft"] as? Bool ?? false,
        order: yaml["order"] as? Int,
        series: yaml["series"] as? String,
        body: body
    )
}
