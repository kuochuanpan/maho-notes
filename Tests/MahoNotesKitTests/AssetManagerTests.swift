import Testing
import Foundation
@testable import MahoNotesKit

@Suite("AssetManager")
struct AssetManagerTests {
    private func makeTempVault() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func createNote(
        at relativePath: String,
        content: String,
        vaultURL: URL
    ) throws {
        let fileURL = vaultURL.appendingPathComponent(relativePath)
        let parentDir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func createAsset(
        named filename: String,
        inDir dir: String,
        vaultURL: URL,
        content: Data = Data("fake".utf8)
    ) throws {
        let assetsDir = vaultURL
            .appendingPathComponent(dir)
            .appendingPathComponent(AssetManager.assetsDirName)
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        try content.write(to: assetsDir.appendingPathComponent(filename))
    }

    // MARK: - referencedAssets

    @Test func referencedAssetsFindsImages() {
        let md = "# Hello\n![photo](_assets/photo.png)\nSome text"
        let refs = AssetManager.referencedAssets(in: md)
        #expect(refs == ["_assets/photo.png"])
    }

    @Test func referencedAssetsFindsLinks() {
        let md = "See [report](_assets/report.pdf) for details."
        let refs = AssetManager.referencedAssets(in: md)
        #expect(refs == ["_assets/report.pdf"])
    }

    @Test func referencedAssetsFindsMultiple() {
        let md = """
        ![img1](_assets/a.png)
        Some text [doc](_assets/b.pdf)
        ![img2](_assets/c.jpg)
        """
        let refs = AssetManager.referencedAssets(in: md)
        #expect(refs == ["_assets/a.png", "_assets/b.pdf", "_assets/c.jpg"])
    }

    @Test func referencedAssetsDeduplicates() {
        let md = "![a](_assets/same.png) and ![b](_assets/same.png)"
        let refs = AssetManager.referencedAssets(in: md)
        #expect(refs == ["_assets/same.png"])
    }

    @Test func referencedAssetsReturnsEmptyForNoAssets() {
        let md = "# Just text\nNo images or links here.\n[link](https://example.com)"
        let refs = AssetManager.referencedAssets(in: md)
        #expect(refs.isEmpty)
    }

    @Test func referencedAssetsIgnoresNonAssetLinks() {
        let md = "![img](https://example.com/photo.png)\n[link](other/file.txt)"
        let refs = AssetManager.referencedAssets(in: md)
        #expect(refs.isEmpty)
    }

    @Test func referencedAssetsHandlesSpacesInAltText() {
        let md = "![my cool photo](_assets/photo.png)"
        let refs = AssetManager.referencedAssets(in: md)
        #expect(refs == ["_assets/photo.png"])
    }

    // MARK: - assetsDirectory

    @Test func assetsDirectoryReturnsCorrectPath() {
        let url = AssetManager.assetsDirectory(for: "blog/my-note.md", vaultPath: "/vault")
        #expect(url.path == "/vault/blog/_assets")
    }

    @Test func assetsDirectoryForNestedNote() {
        let url = AssetManager.assetsDirectory(for: "blog/drafts/note.md", vaultPath: "/vault")
        #expect(url.path == "/vault/blog/drafts/_assets")
    }

    // MARK: - importAsset

    @Test func importAssetCreatesDirectoryAndCopiesFile() throws {
        let vaultURL = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        // Create collection dir and a note
        let collDir = vaultURL.appendingPathComponent("blog")
        try FileManager.default.createDirectory(at: collDir, withIntermediateDirectories: true)

        // Create a source file to import
        let sourceFile = vaultURL.appendingPathComponent("source-photo.png")
        try Data("fake-image".utf8).write(to: sourceFile)

        let result = try AssetManager.importAsset(
            from: sourceFile,
            forNotePath: "blog/my-note.md",
            vaultPath: vaultURL.path
        )

        #expect(result == "_assets/source-photo.png")

        let importedPath = collDir
            .appendingPathComponent("_assets")
            .appendingPathComponent("source-photo.png")
        #expect(FileManager.default.fileExists(atPath: importedPath.path))
    }

    @Test func importAssetHandlesFilenameConflict() throws {
        let vaultURL = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let collDir = vaultURL.appendingPathComponent("blog")
        try FileManager.default.createDirectory(at: collDir, withIntermediateDirectories: true)

        // Pre-create an existing asset
        try createAsset(named: "photo.png", inDir: "blog", vaultURL: vaultURL)

        // Create source file with same name
        let sourceFile = vaultURL.appendingPathComponent("photo.png")
        try Data("new-image".utf8).write(to: sourceFile)

        let result = try AssetManager.importAsset(
            from: sourceFile,
            forNotePath: "blog/note.md",
            vaultPath: vaultURL.path
        )

        #expect(result == "_assets/photo-1.png")
    }

    @Test func importAssetHandlesMultipleConflicts() throws {
        let vaultURL = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        try createAsset(named: "file.pdf", inDir: "docs", vaultURL: vaultURL)
        try createAsset(named: "file-1.pdf", inDir: "docs", vaultURL: vaultURL)

        let sourceFile = vaultURL.appendingPathComponent("file.pdf")
        try Data("data".utf8).write(to: sourceFile)

        let result = try AssetManager.importAsset(
            from: sourceFile,
            forNotePath: "docs/note.md",
            vaultPath: vaultURL.path
        )

        #expect(result == "_assets/file-2.pdf")
    }

    // MARK: - moveAssets

    @Test func moveAssetsBasicMove() throws {
        let vaultURL = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        try createAsset(named: "img.png", inDir: "source", vaultURL: vaultURL)
        let targetDir = vaultURL.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        try AssetManager.moveAssets(
            referencedPaths: ["_assets/img.png"],
            fromDir: "source",
            toDir: "target",
            vaultPath: vaultURL.path,
            checkShared: false
        )

        let sourcePath = vaultURL.appendingPathComponent("source/_assets/img.png")
        let targetPath = vaultURL.appendingPathComponent("target/_assets/img.png")
        #expect(!FileManager.default.fileExists(atPath: sourcePath.path))
        #expect(FileManager.default.fileExists(atPath: targetPath.path))
    }

    @Test func moveAssetsSharedAssetIsCopied() throws {
        let vaultURL = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        // Create shared asset
        try createAsset(named: "shared.png", inDir: "source", vaultURL: vaultURL, content: Data("shared-data".utf8))

        // Create another note in source that references the same asset (the moved note is already gone)
        try createNote(
            at: "source/other-note.md",
            content: "# Other\n![pic](_assets/shared.png)",
            vaultURL: vaultURL
        )

        let targetDir = vaultURL.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        try AssetManager.moveAssets(
            referencedPaths: ["_assets/shared.png"],
            fromDir: "source",
            toDir: "target",
            vaultPath: vaultURL.path,
            checkShared: true
        )

        // Both should exist (copied, not moved)
        let sourcePath = vaultURL.appendingPathComponent("source/_assets/shared.png")
        let targetPath = vaultURL.appendingPathComponent("target/_assets/shared.png")
        #expect(FileManager.default.fileExists(atPath: sourcePath.path))
        #expect(FileManager.default.fileExists(atPath: targetPath.path))
    }

    @Test func moveAssetsUnsharedAssetIsMoved() throws {
        let vaultURL = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        try createAsset(named: "unique.png", inDir: "source", vaultURL: vaultURL)

        // Create another note that does NOT reference the asset
        try createNote(
            at: "source/other-note.md",
            content: "# Other\nNo asset refs here.",
            vaultURL: vaultURL
        )

        let targetDir = vaultURL.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        try AssetManager.moveAssets(
            referencedPaths: ["_assets/unique.png"],
            fromDir: "source",
            toDir: "target",
            vaultPath: vaultURL.path,
            checkShared: true
        )

        let sourcePath = vaultURL.appendingPathComponent("source/_assets/unique.png")
        let targetPath = vaultURL.appendingPathComponent("target/_assets/unique.png")
        #expect(!FileManager.default.fileExists(atPath: sourcePath.path))
        #expect(FileManager.default.fileExists(atPath: targetPath.path))
    }

    @Test func moveAssetsSkipsMissingFiles() throws {
        let vaultURL = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        let targetDir = vaultURL.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        // Should not throw for missing assets
        try AssetManager.moveAssets(
            referencedPaths: ["_assets/nonexistent.png"],
            fromDir: "source",
            toDir: "target",
            vaultPath: vaultURL.path,
            checkShared: false
        )
    }

    // MARK: - copyAssets

    @Test func copyAssetsBasicCopy() throws {
        let vaultURL = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        try createAsset(named: "doc.pdf", inDir: "source", vaultURL: vaultURL, content: Data("pdf-data".utf8))
        let targetDir = vaultURL.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        try AssetManager.copyAssets(
            referencedPaths: ["_assets/doc.pdf"],
            fromDir: "source",
            toDir: "target",
            vaultPath: vaultURL.path
        )

        let sourcePath = vaultURL.appendingPathComponent("source/_assets/doc.pdf")
        let targetPath = vaultURL.appendingPathComponent("target/_assets/doc.pdf")
        #expect(FileManager.default.fileExists(atPath: sourcePath.path))
        #expect(FileManager.default.fileExists(atPath: targetPath.path))
    }

    @Test func copyAssetsCreatesTargetAssetsDir() throws {
        let vaultURL = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        try createAsset(named: "file.txt", inDir: "source", vaultURL: vaultURL)
        // Target dir exists but target/_assets/ does not
        let targetDir = vaultURL.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        try AssetManager.copyAssets(
            referencedPaths: ["_assets/file.txt"],
            fromDir: "source",
            toDir: "target",
            vaultPath: vaultURL.path
        )

        let targetAssetsDir = vaultURL.appendingPathComponent("target/_assets")
        #expect(FileManager.default.fileExists(atPath: targetAssetsDir.path))
    }

    // MARK: - orphanedAssets

    @Test func orphanedAssetsFindsUnreferenced() throws {
        let vaultURL = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        try createAsset(named: "used.png", inDir: "blog", vaultURL: vaultURL)
        try createAsset(named: "orphan.png", inDir: "blog", vaultURL: vaultURL)

        try createNote(
            at: "blog/note.md",
            content: "# Note\n![img](_assets/used.png)",
            vaultURL: vaultURL
        )

        let orphans = try AssetManager.orphanedAssets(inDirectory: "blog", vaultPath: vaultURL.path)
        #expect(orphans == ["orphan.png"])
    }

    @Test func orphanedAssetsReturnsEmptyWhenAllReferenced() throws {
        let vaultURL = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        try createAsset(named: "img.png", inDir: "blog", vaultURL: vaultURL)

        try createNote(
            at: "blog/note.md",
            content: "![pic](_assets/img.png)",
            vaultURL: vaultURL
        )

        let orphans = try AssetManager.orphanedAssets(inDirectory: "blog", vaultPath: vaultURL.path)
        #expect(orphans.isEmpty)
    }

    @Test func orphanedAssetsReturnsEmptyWhenNoAssetsDir() throws {
        let vaultURL = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        try createNote(
            at: "blog/note.md",
            content: "# Note\nNo assets",
            vaultURL: vaultURL
        )

        let orphans = try AssetManager.orphanedAssets(inDirectory: "blog", vaultPath: vaultURL.path)
        #expect(orphans.isEmpty)
    }

    @Test func orphanedAssetsConsidersMultipleNotes() throws {
        let vaultURL = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        try createAsset(named: "a.png", inDir: "blog", vaultURL: vaultURL)
        try createAsset(named: "b.png", inDir: "blog", vaultURL: vaultURL)
        try createAsset(named: "c.png", inDir: "blog", vaultURL: vaultURL)

        try createNote(
            at: "blog/note1.md",
            content: "![a](_assets/a.png)",
            vaultURL: vaultURL
        )
        try createNote(
            at: "blog/note2.md",
            content: "![b](_assets/b.png)",
            vaultURL: vaultURL
        )

        let orphans = try AssetManager.orphanedAssets(inDirectory: "blog", vaultPath: vaultURL.path)
        #expect(orphans == ["c.png"])
    }

    @Test func orphanedAssetsIgnoresIndexMd() throws {
        let vaultURL = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: vaultURL) }

        try createAsset(named: "orphan.png", inDir: "blog", vaultURL: vaultURL)

        // _index.md references the asset, but it shouldn't count as a note
        try createNote(
            at: "blog/_index.md",
            content: "---\ntitle: Blog\n---\n![pic](_assets/orphan.png)",
            vaultURL: vaultURL
        )

        let orphans = try AssetManager.orphanedAssets(inDirectory: "blog", vaultPath: vaultURL.path)
        #expect(orphans == ["orphan.png"])
    }
}
