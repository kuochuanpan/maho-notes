import Foundation
import Yams

/// A node in the vault file tree — either a directory (collection/subcollection) or a note (leaf).
public final class FileTreeNode: Identifiable, Sendable {
    public let id: String                     // relative path from vault root
    public let name: String                   // display name
    public let icon: String                   // SF Symbol name
    public let isDirectory: Bool
    public let note: Note?                    // non-nil for leaf nodes
    public let children: [FileTreeNode]       // sorted: directories first, then notes

    public init(
        id: String,
        name: String,
        icon: String,
        isDirectory: Bool,
        note: Note? = nil,
        children: [FileTreeNode] = []
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.isDirectory = isDirectory
        self.note = note
        self.children = children
    }
}

extension Vault {
    /// Build a hierarchical file tree from the vault's collections and notes.
    ///
    /// Top-level directories become collection nodes (with icon/name from maho.yaml or _index.md).
    /// Subdirectories become subcollection nodes. Markdown files become note leaves.
    public func buildFileTree() throws -> [FileTreeNode] {
        let collections = try self.collections()
        let collectionMap = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0) })
        let allNotes = try self.allNotes()

        // Group notes by their directory path
        var notesByDir: [String: [Note]] = [:]
        for note in allNotes {
            let dir = (note.relativePath as NSString).deletingLastPathComponent
            notesByDir[dir, default: []].append(note)
        }

        // Discover all directories in the vault (recursively)
        let fm = FileManager.default
        let vaultURL = URL(fileURLWithPath: path)

        // Build set of all directory paths that contain notes (directly or in subdirs)
        var allDirs: Set<String> = []
        for note in allNotes {
            let components = note.relativePath.split(separator: "/").dropLast() // drop filename
            var current = ""
            for comp in components {
                current = current.isEmpty ? String(comp) : current + "/" + String(comp)
                allDirs.insert(current)
            }
        }

        // Build tree recursively from top-level directories
        func buildNode(relativePath: String, depth: Int) -> FileTreeNode? {
            let dirName = (relativePath as NSString).lastPathComponent
            let absPath = vaultURL.appendingPathComponent(relativePath).path

            guard fm.fileExists(atPath: absPath) else { return nil }

            // Get display info
            let name: String
            let icon: String

            if depth == 0, let col = collectionMap[dirName] {
                // Top-level collection with maho.yaml metadata
                name = col.name
                icon = col.icon.isEmpty ? "folder" : col.icon
            } else {
                // Subcollection — check _index.md for title, else use dirname
                let indexPath = (absPath as NSString).appendingPathComponent("_index.md")
                if let indexContent = try? String(contentsOfFile: indexPath, encoding: .utf8) {
                    let (yamlStr, _) = splitFrontmatter(indexContent)
                    if let yamlStr,
                       let yaml = try? Yams.load(yaml: yamlStr) as? [String: Any],
                       let title = yaml["title"] as? String {
                        name = title
                    } else {
                        name = dirName
                    }
                } else {
                    name = dirName
                }
                icon = "folder"
            }

            // Find child directories
            let childDirs = allDirs.filter { dirPath in
                let parent = (dirPath as NSString).deletingLastPathComponent
                return parent == relativePath
            }.sorted()

            // Build child directory nodes
            var children: [FileTreeNode] = childDirs.compactMap { childDir in
                buildNode(relativePath: childDir, depth: depth + 1)
            }

            // Add note leaves for this directory
            let dirNotes = (notesByDir[relativePath] ?? []).sorted { $0.title < $1.title }
            for note in dirNotes {
                children.append(FileTreeNode(
                    id: note.relativePath,
                    name: note.title,
                    icon: "doc.text",
                    isDirectory: false,
                    note: note
                ))
            }

            // Skip empty directories (no children at all)
            guard !children.isEmpty else { return nil }

            return FileTreeNode(
                id: relativePath,
                name: name,
                icon: icon,
                isDirectory: true,
                children: children
            )
        }

        // Get top-level directories
        let topLevelDirs = allDirs.filter { !$0.contains("/") }.sorted()

        // Build top-level nodes, preserving maho.yaml order for defined collections
        let definedIds = collections.map { $0.id }
        let discoveredIds = topLevelDirs.filter { !definedIds.contains($0) }
        let orderedIds = definedIds + discoveredIds

        return orderedIds.compactMap { dirId in
            buildNode(relativePath: dirId, depth: 0)
        }
    }
}
