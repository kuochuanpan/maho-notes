import Foundation

/// Manages `_assets/` directories for note attachments (images, files).
///
/// Each collection directory can have a shared `_assets/` subdirectory.
/// Notes reference assets via relative paths like `_assets/photo.png`.
public enum AssetManager {
    /// Name of the assets subdirectory.
    public static let assetsDirName = "_assets"

    /// Get the `_assets/` directory URL for a note at the given relative path.
    public static func assetsDirectory(for notePath: String, vaultPath: String) -> URL {
        let noteDir = (notePath as NSString).deletingLastPathComponent
        let vaultURL = URL(fileURLWithPath: vaultPath)
        return vaultURL
            .appendingPathComponent(noteDir)
            .appendingPathComponent(assetsDirName)
    }

    /// Scan markdown text for asset references (images and file links).
    ///
    /// Matches patterns like `![alt](_assets/file.png)` and `[text](_assets/doc.pdf)`.
    /// Returns the relative paths (e.g. `["_assets/diagram.png"]`).
    public static func referencedAssets(in markdown: String) -> [String] {
        // Match both ![...](_assets/...) and [...](_assets/...)
        let pattern = #"!?\[.*?\]\((_assets/[^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let range = NSRange(markdown.startIndex..., in: markdown)
        let matches = regex.matches(in: markdown, range: range)

        var paths: [String] = []
        for match in matches {
            guard let captureRange = Range(match.range(at: 1), in: markdown) else { continue }
            let path = String(markdown[captureRange])
            if !paths.contains(path) {
                paths.append(path)
            }
        }
        return paths
    }

    /// Import a file into the `_assets/` directory for the given note.
    ///
    /// Creates `_assets/` if it doesn't exist. Handles filename conflicts
    /// by appending `-1`, `-2`, etc. before the extension.
    /// - Returns: The relative path to use in markdown (e.g. `_assets/photo.png`).
    public static func importAsset(
        from sourceURL: URL,
        forNotePath: String,
        vaultPath: String
    ) throws -> String {
        let fm = FileManager.default
        let assetsDir = assetsDirectory(for: forNotePath, vaultPath: vaultPath)

        if !fm.fileExists(atPath: assetsDir.path) {
            try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        }

        let originalName = sourceURL.lastPathComponent
        let ext = (originalName as NSString).pathExtension
        let baseName = (originalName as NSString).deletingPathExtension

        var targetName = originalName
        var targetURL = assetsDir.appendingPathComponent(targetName)
        var counter = 1
        while fm.fileExists(atPath: targetURL.path) {
            targetName = ext.isEmpty ? "\(baseName)-\(counter)" : "\(baseName)-\(counter).\(ext)"
            targetURL = assetsDir.appendingPathComponent(targetName)
            counter += 1
        }

        try fm.copyItem(at: sourceURL, to: targetURL)
        return "\(assetsDirName)/\(targetName)"
    }

    /// Move assets referenced by a note from one directory to another.
    ///
    /// - Parameters:
    ///   - referencedPaths: Asset paths like `["_assets/photo.png"]`.
    ///   - fromDir: Source directory relative path (e.g. `"blog"`).
    ///   - toDir: Target directory relative path (e.g. `"archive"`).
    ///   - vaultPath: Absolute path to the vault root.
    ///   - checkShared: If true, copies (instead of moves) assets referenced by other notes in the source directory.
    public static func moveAssets(
        referencedPaths: [String],
        fromDir: String,
        toDir: String,
        vaultPath: String,
        checkShared: Bool
    ) throws {
        guard !referencedPaths.isEmpty else { return }

        let fm = FileManager.default
        let vaultURL = URL(fileURLWithPath: vaultPath)
        let targetAssetsDir = vaultURL
            .appendingPathComponent(toDir)
            .appendingPathComponent(assetsDirName)

        // Collect other notes' references if we need to check for shared assets
        var otherReferences: Set<String> = []
        if checkShared {
            otherReferences = try sharedAssetReferences(
                inDirectory: fromDir,
                vaultPath: vaultPath
            )
        }

        for assetPath in referencedPaths {
            let sourceFile = vaultURL
                .appendingPathComponent(fromDir)
                .appendingPathComponent(assetPath)
            guard fm.fileExists(atPath: sourceFile.path) else { continue }

            if !fm.fileExists(atPath: targetAssetsDir.path) {
                try fm.createDirectory(at: targetAssetsDir, withIntermediateDirectories: true)
            }

            let filename = (assetPath as NSString).lastPathComponent
            let targetFile = targetAssetsDir.appendingPathComponent(filename)

            if checkShared && otherReferences.contains(assetPath) {
                // Shared asset: copy instead of move
                if !fm.fileExists(atPath: targetFile.path) {
                    try fm.copyItem(at: sourceFile, to: targetFile)
                }
            } else {
                // Not shared: move
                if !fm.fileExists(atPath: targetFile.path) {
                    try fm.moveItem(at: sourceFile, to: targetFile)
                }
            }
        }
    }

    /// Copy assets referenced by a note to a new directory.
    public static func copyAssets(
        referencedPaths: [String],
        fromDir: String,
        toDir: String,
        vaultPath: String
    ) throws {
        guard !referencedPaths.isEmpty else { return }

        let fm = FileManager.default
        let vaultURL = URL(fileURLWithPath: vaultPath)
        let targetAssetsDir = vaultURL
            .appendingPathComponent(toDir)
            .appendingPathComponent(assetsDirName)

        for assetPath in referencedPaths {
            let sourceFile = vaultURL
                .appendingPathComponent(fromDir)
                .appendingPathComponent(assetPath)
            guard fm.fileExists(atPath: sourceFile.path) else { continue }

            if !fm.fileExists(atPath: targetAssetsDir.path) {
                try fm.createDirectory(at: targetAssetsDir, withIntermediateDirectories: true)
            }

            let filename = (assetPath as NSString).lastPathComponent
            let targetFile = targetAssetsDir.appendingPathComponent(filename)

            if !fm.fileExists(atPath: targetFile.path) {
                try fm.copyItem(at: sourceFile, to: targetFile)
            }
        }
    }

    /// Find orphaned assets in a directory's `_assets/` that aren't referenced by any note.
    ///
    /// Scans all `.md` files in the directory and returns asset filenames not referenced by any of them.
    public static func orphanedAssets(inDirectory dir: String, vaultPath: String) throws -> [String] {
        let fm = FileManager.default
        let vaultURL = URL(fileURLWithPath: vaultPath)
        let assetsDir = vaultURL
            .appendingPathComponent(dir)
            .appendingPathComponent(assetsDirName)

        guard fm.fileExists(atPath: assetsDir.path) else { return [] }

        // Get all files in _assets/
        let assetFiles = try fm.contentsOfDirectory(atPath: assetsDir.path)
            .filter { !$0.hasPrefix(".") }

        guard !assetFiles.isEmpty else { return [] }

        // Collect all asset references from notes in this directory
        let allReferences = try collectReferences(inDirectory: dir, vaultPath: vaultPath)
        let referencedFilenames = Set(allReferences.map { ($0 as NSString).lastPathComponent })

        return assetFiles.filter { !referencedFilenames.contains($0) }.sorted()
    }

    // MARK: - Private Helpers

    /// Collect all asset references from markdown files in a directory.
    private static func collectReferences(
        inDirectory dir: String,
        vaultPath: String
    ) throws -> Set<String> {
        let fm = FileManager.default
        let vaultURL = URL(fileURLWithPath: vaultPath)
        let dirURL = vaultURL.appendingPathComponent(dir)

        guard fm.fileExists(atPath: dirURL.path) else { return [] }

        let contents = try fm.contentsOfDirectory(atPath: dirURL.path)
        var allRefs: Set<String> = []

        for filename in contents where filename.hasSuffix(".md") && filename != "_index.md" {
            let filePath = dirURL.appendingPathComponent(filename).path
            guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { continue }
            let refs = referencedAssets(in: content)
            allRefs.formUnion(refs)
        }

        return allRefs
    }

    /// Collect asset references from remaining notes in a directory (for shared-asset detection).
    ///
    /// Called after the note file has already been moved out, so only remaining notes are scanned.
    private static func sharedAssetReferences(
        inDirectory dir: String,
        vaultPath: String
    ) throws -> Set<String> {
        try collectReferences(inDirectory: dir, vaultPath: vaultPath)
    }
}
