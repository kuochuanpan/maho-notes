import Foundation

public struct Chunk: Sendable {
    public let id: Int
    public let text: String
}

public enum Chunker {
    /// Split note into chunks for embedding.
    /// Short notes (< 500 chars): single chunk with title prefix.
    /// Long notes: split by markdown headings, each with title prefix.
    public static func chunkNote(title: String, body: String) -> [Chunk] {
        let stripped = stripFrontmatter(body)
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return [Chunk(id: 0, text: title)]
        }

        if trimmed.count < 500 {
            return [Chunk(id: 0, text: "\(title): \(trimmed)")]
        }

        // Split on heading lines
        let lines = trimmed.components(separatedBy: "\n")
        var sections: [(heading: String?, content: [String])] = []
        var currentHeading: String? = nil
        var currentLines: [String] = []

        for line in lines {
            if line.hasPrefix("#") {
                if !currentLines.isEmpty || sections.isEmpty {
                    sections.append((heading: currentHeading, content: currentLines))
                }
                currentHeading = line.drop(while: { $0 == "#" || $0 == " " }).trimmingCharacters(in: .whitespaces)
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }
        sections.append((heading: currentHeading, content: currentLines))

        var chunks: [Chunk] = []
        var id = 0
        for section in sections {
            let content = section.content.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }

            let prefix: String
            if let heading = section.heading {
                prefix = "\(title) — \(heading): "
            } else {
                prefix = "\(title): "
            }
            chunks.append(Chunk(id: id, text: prefix + content))
            id += 1
        }

        if chunks.isEmpty {
            return [Chunk(id: 0, text: title)]
        }
        return chunks
    }

    private static func stripFrontmatter(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else { return body }

        // Find closing ---
        let afterFirst = trimmed.dropFirst(3)
        guard let range = afterFirst.range(of: "\n---") else { return body }
        let afterFrontmatter = afterFirst[range.upperBound...]
        return String(afterFrontmatter)
    }
}
