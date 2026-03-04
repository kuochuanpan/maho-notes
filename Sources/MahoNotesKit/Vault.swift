import Foundation

/// Provides operations on a maho-vault directory
public struct Vault: Sendable {
    public let path: String

    public init(path: String) {
        self.path = (path as NSString).expandingTildeInPath
    }

    /// Load all collections defined in collections.yaml
    public func collections() throws -> [Collection] {
        try loadCollections(from: path)
    }

    /// Find all markdown files in the vault (excluding _index.md files)
    public func allNoteFiles() throws -> [String] {
        let vaultURL = URL(fileURLWithPath: path)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [String] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "md",
                  fileURL.lastPathComponent != "_index.md"
            else { continue }
            files.append(fileURL.path)
        }
        return files.sorted()
    }

    /// Parse all notes in the vault
    public func allNotes() throws -> [Note] {
        let files = try allNoteFiles()
        return files.compactMap { filePath in
            try? parseNote(at: filePath, relativeTo: path)
        }
    }

    /// List notes, optionally filtered by collection or tag
    public func listNotes(collection: String? = nil, tag: String? = nil) throws -> [Note] {
        var notes = try allNotes()
        if let collection {
            notes = notes.filter { $0.collection == collection }
        }
        if let tag {
            notes = notes.filter { $0.tags.contains(tag) }
        }
        return notes
    }

    /// Show a specific note by its relative path
    public func showNote(relativePath: String) throws -> Note? {
        let filePath = (path as NSString).appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: filePath) else {
            return nil
        }
        return try parseNote(at: filePath, relativeTo: path)
    }

    /// Search notes by substring match across title, tags, and body
    public func searchNotes(query: String) throws -> [Note] {
        let lowercased = query.lowercased()
        let notes = try allNotes()
        return notes.filter { note in
            note.title.lowercased().contains(lowercased)
                || note.body.lowercased().contains(lowercased)
                || note.tags.contains(where: { $0.lowercased().contains(lowercased) })
        }
    }

    /// Create a new note with proper frontmatter
    public func createNote(
        title: String,
        collection: String,
        tags: [String],
        author: String = "kuochuan"
    ) throws -> String {
        // Build filename from title
        let slug = makeSlug(from: title)
        let collectionDir = (path as NSString).appendingPathComponent(collection)
        let fm = FileManager.default

        // Ensure collection directory exists
        if !fm.fileExists(atPath: collectionDir) {
            try fm.createDirectory(atPath: collectionDir, withIntermediateDirectories: true)
        }

        // Find next number prefix by scanning existing files
        let nextNum = try nextFileNumber(in: collectionDir)
        let filename = String(format: "%03d-%@.md", nextNum, slug)
        let filePath = (collectionDir as NSString).appendingPathComponent(filename)

        let now = ISO8601DateFormatter().string(from: Date())
        let tagsYaml = tags.isEmpty ? "[]" : "[\(tags.joined(separator: ", "))]"

        let content = """
        ---
        title: \(title)
        collection: \(collection)
        tags: \(tagsYaml)
        created: \(now)
        updated: \(now)
        public: false
        author: \(author)
        ---

        # \(title)


        """

        try content.write(toFile: filePath, atomically: true, encoding: .utf8)

        // Return relative path
        let vaultURL = URL(fileURLWithPath: path).standardizedFileURL
        let fileURL = URL(fileURLWithPath: filePath).standardizedFileURL
        return fileURL.path.replacingOccurrences(of: vaultURL.path + "/", with: "")
    }
}

// MARK: - Helpers

func makeSlug(from title: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
    return title
        .lowercased()
        .components(separatedBy: .whitespaces)
        .joined(separator: "-")
        .unicodeScalars
        .filter { allowed.contains($0) }
        .map { String($0) }
        .joined()
}

func nextFileNumber(in directory: String) throws -> Int {
    let fm = FileManager.default
    guard fm.fileExists(atPath: directory) else { return 1 }
    let contents = try fm.contentsOfDirectory(atPath: directory)
    let numbers = contents.compactMap { name -> Int? in
        guard name.hasSuffix(".md"), name != "_index.md" else { return nil }
        let prefix = name.prefix(while: { $0.isNumber })
        return Int(prefix)
    }
    return (numbers.max() ?? 0) + 1
}
