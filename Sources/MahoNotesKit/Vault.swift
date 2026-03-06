import Foundation
import Yams

/// Provides operations on a maho-vault directory
public struct Vault: Sendable {
    public let path: String

    public init(path: String) {
        self.path = (path as NSString).expandingTildeInPath
    }

    /// Load all collections: defined in maho.yaml + discovered from filesystem
    public func collections() throws -> [Collection] {
        let defined = try loadCollections(from: path)
        let definedIds = Set(defined.map { $0.id })

        // Discover collection directories not in collections.yaml
        let fm = FileManager.default
        let vaultURL = URL(fileURLWithPath: path)
        let contents = try fm.contentsOfDirectory(at: vaultURL, includingPropertiesForKeys: [.isDirectoryKey])
        var discovered: [Collection] = []

        for item in contents {
            var isDir: ObjCBool = false
            let name = item.lastPathComponent
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir),
                  isDir.boolValue,
                  !name.hasPrefix("."),
                  !name.hasPrefix("_"),
                  !definedIds.contains(name)
            else { continue }

            // Include all directories as collections — empty ones represent
            // user-created collections that don't have notes yet.

            // Check _index.md for metadata
            let indexPath = item.appendingPathComponent("_index.md").path
            var displayName = name
            var description = ""
            if fm.fileExists(atPath: indexPath),
               let indexContent = try? String(contentsOfFile: indexPath, encoding: .utf8) {
                let (yamlStr, _) = splitFrontmatter(indexContent)
                if let yamlStr,
                   let yaml = try? Yams.load(yaml: yamlStr) as? [String: Any] {
                    displayName = yaml["title"] as? String ?? name
                    description = yaml["description"] as? String ?? ""
                }
            }

            discovered.append(Collection(
                id: name,
                name: displayName,
                icon: "folder",  // default SF Symbol
                description: description
            ))
        }

        return defined + discovered.sorted(by: { $0.id < $1.id })
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
            let filename = fileURL.lastPathComponent
            guard fileURL.pathExtension == "md",
                  filename != "_index.md",
                  filename.lowercased() != "readme.md"
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
            notes = notes.filter { $0.relativePath.hasPrefix(collection + "/") }
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

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        let now = dateFormatter.string(from: Date())
        let tagsYaml = tags.isEmpty ? "[]" : "[\(tags.joined(separator: ", "))]"

        let content = """
        ---
        title: \(title)
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

    /// Reorder notes in a collection by renumbering their file prefixes.
    /// - Parameters:
    ///   - collectionId: Directory relative path from vault root (e.g. "blog" or "blog/drafts").
    ///   - orderedPaths: The note relative paths in desired order.
    /// - Returns: A mapping of old relative paths → new relative paths.
    @discardableResult
    public func reorderNotes(collectionId: String, orderedPaths: [String]) throws -> [String: String] {
        let fm = FileManager.default
        let vaultURL = URL(fileURLWithPath: path)
        var renames: [String: String] = [:]

        // First pass: rename to temp names to avoid collisions
        var tempPaths: [(old: String, temp: String, newName: String)] = []
        for (index, relPath) in orderedPaths.enumerated() {
            let filename = (relPath as NSString).lastPathComponent
            // Strip existing numeric prefix (e.g. "001-slug.md" → "slug.md")
            let slug: String
            let prefixEnd = filename.prefix(while: { $0.isNumber })
            if !prefixEnd.isEmpty && filename.dropFirst(prefixEnd.count).hasPrefix("-") {
                slug = String(filename.dropFirst(prefixEnd.count + 1)) // drop "NNN-"
            } else {
                slug = filename
            }

            let newFilename = String(format: "%03d-%@", index + 1, slug)
            let newRelPath = (collectionId as NSString).appendingPathComponent(newFilename)

            if relPath != newRelPath {
                let oldAbs = vaultURL.appendingPathComponent(relPath).path
                let tempFilename = ".reorder-tmp-\(index)-\(slug)"
                let tempRelPath = (collectionId as NSString).appendingPathComponent(tempFilename)
                let tempAbs = vaultURL.appendingPathComponent(tempRelPath).path

                guard fm.fileExists(atPath: oldAbs) else { continue }
                try fm.moveItem(atPath: oldAbs, toPath: tempAbs)
                tempPaths.append((old: relPath, temp: tempRelPath, newName: newFilename))
                renames[relPath] = newRelPath
            }
        }

        // Second pass: rename from temp to final
        for item in tempPaths {
            let tempAbs = vaultURL.appendingPathComponent(item.temp).path
            let finalRelPath = (collectionId as NSString).appendingPathComponent(item.newName)
            let finalAbs = vaultURL.appendingPathComponent(finalRelPath).path
            try fm.moveItem(atPath: tempAbs, toPath: finalAbs)
        }

        return renames
    }
}

// MARK: - Helpers

/// Check if a directory contains any .md files (recursively), excluding _index.md
private func hasMarkdownFiles(in directoryPath: String, fileManager fm: FileManager) -> Bool {
    guard let enumerator = fm.enumerator(
        at: URL(fileURLWithPath: directoryPath),
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return false }

    for case let fileURL as URL in enumerator {
        if fileURL.pathExtension == "md"
            && fileURL.lastPathComponent != "_index.md"
            && fileURL.lastPathComponent.lowercased() != "readme.md" {
            return true
        }
    }
    return false
}

public func makeSlug(from title: String) -> String {
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

public func nextFileNumber(in directory: String) throws -> Int {
    let fm = FileManager.default
    guard fm.fileExists(atPath: directory) else { return 1 }
    let contents = try fm.contentsOfDirectory(atPath: directory)
    let numbers = contents.compactMap { name -> Int? in
        guard name.hasSuffix(".md"), name != "_index.md", name.lowercased() != "readme.md" else { return nil }
        let prefix = name.prefix(while: { $0.isNumber })
        return Int(prefix)
    }
    return (numbers.max() ?? 0) + 1
}
