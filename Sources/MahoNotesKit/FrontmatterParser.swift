import Foundation
import Yams

/// Splits a markdown file into (YAML frontmatter string, body content).
/// Returns nil for frontmatter if no valid `---` delimiters are found.
public func splitFrontmatter(_ content: String) -> (yaml: String?, body: String) {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("---") else {
        return (nil, content)
    }

    let lines = content.components(separatedBy: "\n")
    // Find the opening --- line (may not be line 0 if there's leading whitespace)
    var openingIndex: Int?
    for i in 0..<lines.count {
        if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            openingIndex = i
            break
        }
    }
    guard let startIdx = openingIndex else {
        return (nil, content)
    }
    // Find closing ---
    var closingIndex: Int?
    for i in (startIdx + 1)..<lines.count {
        if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            closingIndex = i
            break
        }
    }

    guard let endIdx = closingIndex else {
        return (nil, content)
    }

    let yamlLines = lines[(startIdx + 1)..<endIdx]
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

/// Update the `public` field in a note's YAML frontmatter.
/// Rewrites the file in place, preserving all other content.
public func setFrontmatterPublic(filePath: String, isPublic: Bool) throws {
    let content = try String(contentsOfFile: filePath, encoding: .utf8)
    let (yamlStr, body) = splitFrontmatter(content)

    guard var yamlStr else {
        throw NSError(domain: "MahoNotesKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "No frontmatter found in \(filePath)"])
    }

    // Replace or add the public field
    let publicLine = "public: \(isPublic)"
    let lines = yamlStr.components(separatedBy: "\n")
    var found = false
    let updatedLines = lines.map { line -> String in
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("public:") {
            found = true
            return publicLine
        }
        return line
    }

    if found {
        yamlStr = updatedLines.joined(separator: "\n")
    } else {
        yamlStr += "\n" + publicLine
    }

    let output = "---\n\(yamlStr)\n---\(body)"
    try output.write(toFile: filePath, atomically: true, encoding: .utf8)
}

/// Parses a markdown file at the given path into a Note
public func parseNote(at filePath: String, relativeTo vaultPath: String) throws -> Note? {
    let content = try String(contentsOfFile: filePath, encoding: .utf8)

    // Strip BOM if present
    let cleaned = content.hasPrefix("\u{FEFF}") ? String(content.dropFirst()) : content

    let (yamlStr, body) = splitFrontmatter(cleaned)

    // Compute relative path from vault root
    let vaultURL = URL(fileURLWithPath: vaultPath).standardizedFileURL
    let fileURL = URL(fileURLWithPath: filePath).standardizedFileURL
    let relPath = fileURL.path.replacingOccurrences(of: vaultURL.path + "/", with: "")

    // Fallback title from filename (without extension and leading number prefix like "001-")
    let fallbackTitle: String = {
        var name = (filePath as NSString).lastPathComponent
        if name.hasSuffix(".md") { name = String(name.dropLast(3)) }
        // Strip leading number prefix like "001-"
        if let range = name.range(of: #"^\d+-"#, options: .regularExpression) {
            name = String(name[range.upperBound...])
        }
        return name
    }()

    // Parse frontmatter if present; notes without frontmatter still show up
    let yaml: [String: Any]
    if let yamlStr,
       let parsed = try? Yams.load(yaml: yamlStr) as? [String: Any] {
        yaml = parsed
    } else {
        yaml = [:]
    }

    let title = yaml["title"] as? String ?? fallbackTitle

    let tags: [String]
    if let tagArray = yaml["tags"] as? [String] {
        tags = tagArray
    } else if let tagStr = yaml["tags"] as? String {
        tags = tagStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    } else {
        tags = []
    }

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
