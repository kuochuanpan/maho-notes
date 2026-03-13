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

    /// Search notes by substring match across title, tags, and body.
    ///
    /// - Note: This is an O(n) brute-force scan used only as a fallback when FTS5 is unavailable.
    ///   Prefer `VaultSearchService.search()` or `SearchIndex` for production search.
    @available(*, deprecated, message: "Use VaultSearchService or SearchIndex for efficient search")
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

        // Use clean slug filename (no numeric prefix)
        let filename = "\(slug).md"
        var filePath = (collectionDir as NSString).appendingPathComponent(filename)

        // Handle filename conflicts
        var counter = 1
        while fm.fileExists(atPath: filePath) {
            let conflictName = "\(slug)-\(counter).md"
            filePath = (collectionDir as NSString).appendingPathComponent(conflictName)
            counter += 1
        }
        let actualFilename = (filePath as NSString).lastPathComponent

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

        // Append to _index.md order
        let (existingOrder, _) = readDirectoryOrder(at: collectionDir)
        var newOrder = existingOrder
        newOrder.append(actualFilename)
        try writeDirectoryOrder(at: collectionDir, notes: newOrder)

        // Return relative path
        let vaultURL = URL(fileURLWithPath: path).standardizedFileURL
        let fileURL = URL(fileURLWithPath: filePath).standardizedFileURL
        return fileURL.path.replacingOccurrences(of: vaultURL.path + "/", with: "")
    }

    /// Reorder notes in a collection by writing the order to `_index.md`.
    /// - Parameters:
    ///   - collectionId: Directory relative path from vault root (e.g. "blog" or "blog/drafts").
    ///   - orderedPaths: The note relative paths in desired order.
    /// - Returns: An empty mapping (no file renames happen).
    @discardableResult
    public func reorderNotes(collectionId: String, orderedPaths: [String]) throws -> [String: String] {
        let dirPath = (path as NSString).appendingPathComponent(collectionId)
        let filenames = orderedPaths.map { ($0 as NSString).lastPathComponent }
        try writeDirectoryOrder(at: dirPath, notes: filenames)
        return [:]
    }

    /// Reorder sub-collections within a parent directory by writing to `_index.md`.
    public func reorderSubCollections(parentId: String, orderedIds: [String]) throws {
        let dirPath = (path as NSString).appendingPathComponent(parentId)
        let dirNames = orderedIds.map { ($0 as NSString).lastPathComponent }
        try writeDirectoryOrder(at: dirPath, children: dirNames)
    }

    /// Move a note from its current location to a target collection directory.
    /// - Returns: The new relative path.
    public func moveNote(relativePath: String, toCollection: String) throws -> String {
        let fm = FileManager.default
        let vaultURL = URL(fileURLWithPath: path)
        let filename = (relativePath as NSString).lastPathComponent
        let sourceDir = (relativePath as NSString).deletingLastPathComponent

        let targetDirAbs = vaultURL.appendingPathComponent(toCollection).path
        if !fm.fileExists(atPath: targetDirAbs) {
            try fm.createDirectory(atPath: targetDirAbs, withIntermediateDirectories: true)
        }

        // Handle filename conflicts — use the base name (strip any existing -N suffix)
        var targetFilename = filename
        var targetAbs = (targetDirAbs as NSString).appendingPathComponent(targetFilename)
        if fm.fileExists(atPath: targetAbs) {
            let ext = (filename as NSString).pathExtension
            var baseName = (filename as NSString).deletingPathExtension
            // Strip existing conflict suffix (e.g., "bbbb-1" → "bbbb")
            if let range = baseName.range(of: #"-\d+$"#, options: .regularExpression) {
                baseName = String(baseName[..<range.lowerBound])
            }
            var counter = 1
            repeat {
                targetFilename = "\(baseName)-\(counter).\(ext)"
                targetAbs = (targetDirAbs as NSString).appendingPathComponent(targetFilename)
                counter += 1
            } while fm.fileExists(atPath: targetAbs)
        }

        let sourceAbs = vaultURL.appendingPathComponent(relativePath).path
        try fm.moveItem(atPath: sourceAbs, toPath: targetAbs)

        // Remove from source _index.md order
        let sourceDirAbs = vaultURL.appendingPathComponent(sourceDir).path
        let (sourceOrder, _) = readDirectoryOrder(at: sourceDirAbs)
        if sourceOrder.contains(filename) {
            let updatedOrder = sourceOrder.filter { $0 != filename }
            try writeDirectoryOrder(at: sourceDirAbs, notes: updatedOrder)
        }

        // Append to target _index.md order
        let (targetOrder, _) = readDirectoryOrder(at: targetDirAbs)
        var newOrder = targetOrder
        newOrder.append(targetFilename)
        try writeDirectoryOrder(at: targetDirAbs, notes: newOrder)

        // Update the note's frontmatter updated timestamp
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let now = isoFormatter.string(from: Date())
        updateFrontmatterField(filePath: targetAbs, field: "updated", value: now)

        return (toCollection as NSString).appendingPathComponent(targetFilename)
    }

    /// Move a collection directory into another parent directory.
    /// - Returns: The new relative path.
    public func moveCollection(collectionId: String, intoParent: String) throws -> String {
        let fm = FileManager.default
        let vaultURL = URL(fileURLWithPath: path)
        let dirName = (collectionId as NSString).lastPathComponent
        let sourceParent = (collectionId as NSString).deletingLastPathComponent

        // Prevent circular moves
        let targetWithSlash = collectionId + "/"
        if intoParent == collectionId || intoParent.hasPrefix(targetWithSlash) {
            throw VaultError.circularMove
        }

        let sourceAbs = vaultURL.appendingPathComponent(collectionId).path
        let targetParentAbs = vaultURL.appendingPathComponent(intoParent).path
        let targetAbs = (targetParentAbs as NSString).appendingPathComponent(dirName)

        guard !fm.fileExists(atPath: targetAbs) else {
            throw VaultError.destinationExists
        }

        try fm.moveItem(atPath: sourceAbs, toPath: targetAbs)

        // If source was a top-level collection, remove from maho.yaml
        if !sourceParent.contains("/") && sourceParent.isEmpty {
            try? removeCollectionFromConfig(vaultPath: path, id: dirName)
        }

        // Remove from source parent's _index.md children
        if !sourceParent.isEmpty {
            let sourceParentAbs = vaultURL.appendingPathComponent(sourceParent).path
            let (_, sourceChildren) = readDirectoryOrder(at: sourceParentAbs)
            if sourceChildren.contains(dirName) {
                let updated = sourceChildren.filter { $0 != dirName }
                try writeDirectoryOrder(at: sourceParentAbs, children: updated)
            }
        }

        // Add to target's _index.md children
        let (_, targetChildren) = readDirectoryOrder(at: targetParentAbs)
        var newChildren = targetChildren
        newChildren.append(dirName)
        try writeDirectoryOrder(at: targetParentAbs, children: newChildren)

        return (intoParent as NSString).appendingPathComponent(dirName)
    }

    /// Promote a sub-collection to a top-level collection.
    /// Moves the directory from its current parent to the vault root and registers it in maho.yaml.
    /// - Returns: The new relative path (just the directory name).
    public func promoteToTopLevel(collectionId: String) throws -> String {
        let fm = FileManager.default
        let vaultURL = URL(fileURLWithPath: path)
        let dirName = (collectionId as NSString).lastPathComponent
        let sourceParent = (collectionId as NSString).deletingLastPathComponent

        // Already top-level?
        guard !sourceParent.isEmpty else {
            throw VaultError.circularMove
        }

        let sourceAbs = vaultURL.appendingPathComponent(collectionId).path
        let targetAbs = vaultURL.appendingPathComponent(dirName).path

        guard !fm.fileExists(atPath: targetAbs) else {
            throw VaultError.destinationExists
        }

        try fm.moveItem(atPath: sourceAbs, toPath: targetAbs)

        // Remove from source parent's _index.md children
        let sourceParentAbs = vaultURL.appendingPathComponent(sourceParent).path
        let (_, sourceChildren) = readDirectoryOrder(at: sourceParentAbs)
        if sourceChildren.contains(dirName) {
            let updated = sourceChildren.filter { $0 != dirName }
            try writeDirectoryOrder(at: sourceParentAbs, children: updated)
        }

        // Read title from _index.md for the collection name
        let indexPath = (targetAbs as NSString).appendingPathComponent("_index.md")
        var displayName = dirName
        if let content = try? String(contentsOfFile: indexPath, encoding: .utf8) {
            let (yamlStr, _) = splitFrontmatter(content)
            if let yamlStr,
               let yaml = try? Yams.load(yaml: yamlStr) as? [String: Any],
               let title = yaml["title"] as? String {
                displayName = title
            }
        }

        // Register in maho.yaml
        try addCollection(vaultPath: path, id: dirName, name: displayName, icon: "folder")

        return dirName
    }

    /// Rename a note by updating its frontmatter title field.
    /// The file on disk is NOT renamed — only the display title changes.
    public func renameNote(relativePath: String, newTitle: String) {
        let filePath = (path as NSString).appendingPathComponent(relativePath)
        updateFrontmatterField(filePath: filePath, field: "title", value: newTitle)
    }

    /// Rename a sub-collection by updating its _index.md frontmatter title.
    public func renameSubCollection(collectionId: String, newName: String) throws {
        let dirPath = (path as NSString).appendingPathComponent(collectionId)
        let indexPath = (dirPath as NSString).appendingPathComponent("_index.md")

        if FileManager.default.fileExists(atPath: indexPath) {
            updateFrontmatterField(filePath: indexPath, field: "title", value: newName)
        } else {
            // Create _index.md with the title
            let content = "---\ntitle: \(newName)\n---\n"
            try content.write(toFile: indexPath, atomically: true, encoding: .utf8)
        }
    }

    /// Migrate files with numeric prefixes (e.g., `001-slug.md`) to clean filenames,
    /// populating `_index.md` order to preserve the original ordering.
    public func migrateNumericPrefixes() throws {
        let fm = FileManager.default
        let vaultURL = URL(fileURLWithPath: path)

        guard let enumerator = fm.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        // Collect all directories
        var directories: Set<String> = []
        for case let dirURL as URL in enumerator {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let dirName = dirURL.lastPathComponent
            guard !dirName.hasPrefix("_"), !dirName.hasPrefix(".") else {
                enumerator.skipDescendants()
                continue
            }
            directories.insert(dirURL.path)
        }

        // Also include top-level collection directories
        let topContents = try fm.contentsOfDirectory(at: vaultURL, includingPropertiesForKeys: [.isDirectoryKey])
        for item in topContents {
            var isDir: ObjCBool = false
            let name = item.lastPathComponent
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir),
                  isDir.boolValue,
                  !name.hasPrefix("."),
                  !name.hasPrefix("_") else { continue }
            directories.insert(item.path)
        }

        for dirPath in directories {
            let contents = try fm.contentsOfDirectory(atPath: dirPath)
            let mdFiles = contents.filter { $0.hasSuffix(".md") && $0 != "_index.md" && $0.lowercased() != "readme.md" }

            // Check if any files have numeric prefixes
            let numericPattern = #"^\d+-"#
            let prefixed = mdFiles.filter { $0.range(of: numericPattern, options: .regularExpression) != nil }
            guard !prefixed.isEmpty else { continue }

            // Sort by numeric prefix to preserve order
            let sorted = mdFiles.sorted { a, b in
                a.localizedStandardCompare(b) == .orderedAscending
            }

            // Rename files: strip numeric prefix, build order list
            var orderList: [String] = []
            for oldName in sorted {
                let newName: String
                if let range = oldName.range(of: numericPattern, options: .regularExpression) {
                    newName = String(oldName[range.upperBound...])
                } else {
                    newName = oldName
                }
                orderList.append(newName)

                if newName != oldName {
                    let oldPath = (dirPath as NSString).appendingPathComponent(oldName)
                    let newPath = (dirPath as NSString).appendingPathComponent(newName)
                    // Avoid collision: if target exists (unlikely), skip
                    guard !fm.fileExists(atPath: newPath) else { continue }
                    try fm.moveItem(atPath: oldPath, toPath: newPath)
                }
            }

            // Write order to _index.md
            try writeDirectoryOrder(at: dirPath, notes: orderList)
        }
    }
}

// MoveError moved to VaultError.swift

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

/// Update a single frontmatter field in-place. Best-effort — silently fails if file can't be parsed.
func updateFrontmatterField(filePath: String, field: String, value: String) {
    guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return }
    let lines = content.components(separatedBy: "\n")
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return }

    var closingIndex: Int?
    for i in 1..<lines.count {
        if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            closingIndex = i
            break
        }
    }
    guard let endIdx = closingIndex else { return }

    var updatedLines = lines
    let fieldLine = "\(field): \(value)"
    if let idx = updatedLines[0...endIdx].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(field):") }) {
        updatedLines[idx] = fieldLine
    } else {
        updatedLines.insert(fieldLine, at: endIdx)
    }

    do {
        try updatedLines.joined(separator: "\n").write(toFile: filePath, atomically: true, encoding: .utf8)
    } catch {
        Log.kit.error("updateFrontmatterField failed for \(filePath): \(error)")
    }
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
