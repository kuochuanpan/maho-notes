import Testing
import Foundation
@testable import MahoNotesKit

@Suite("Publish Manifest")
struct PublishManifestTests {

    // MARK: - Helper

    private func makeTempDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func makeNote(
        path: String = "blog/001-test.md",
        title: String = "Test",
        body: String = "Hello world",
        isPublic: Bool = true,
        draft: Bool = false,
        slug: String? = "test",
        tags: [String] = [],
        updated: String = "2025-01-01"
    ) -> Note {
        Note(
            relativePath: path,
            title: title,
            tags: tags,
            created: "2025-01-01",
            updated: updated,
            isPublic: isPublic,
            slug: slug,
            author: nil,
            draft: draft,
            order: nil,
            series: nil,
            body: body
        )
    }

    // MARK: - Load/Save Roundtrip

    @Test func loadSaveRoundtrip() throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }

        var manifest = PublishManifest()
        manifest.entries["blog/001-test.md"] = PublishManifest.ManifestEntry(
            contentHash: "abc123",
            slug: "test",
            collection: "blog",
            generatedAt: "2025-01-01T00:00:00Z"
        )

        try manifest.save(to: tmp.path)
        let loaded = try PublishManifest.load(from: tmp.path)

        #expect(loaded.entries.count == 1)
        #expect(loaded.entries["blog/001-test.md"]?.contentHash == "abc123")
        #expect(loaded.entries["blog/001-test.md"]?.slug == "test")
        #expect(loaded.entries["blog/001-test.md"]?.collection == "blog")
    }

    @Test func loadMissingFileThrows() throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }
        #expect(throws: Error.self) {
            _ = try PublishManifest.load(from: tmp.path)
        }
    }

    // MARK: - Content Hash

    @Test func sameContentSameHash() {
        let note1 = makeNote(body: "Hello world")
        let note2 = makeNote(body: "Hello world")
        #expect(PublishManifest.contentHash(for: note1) == PublishManifest.contentHash(for: note2))
    }

    @Test func differentContentDifferentHash() {
        let note1 = makeNote(body: "Hello world")
        let note2 = makeNote(body: "Different content")
        #expect(PublishManifest.contentHash(for: note1) != PublishManifest.contentHash(for: note2))
    }

    @Test func titleChangesHash() {
        let note1 = makeNote(title: "Title A", body: "Same body")
        let note2 = makeNote(title: "Title B", body: "Same body")
        #expect(PublishManifest.contentHash(for: note1) != PublishManifest.contentHash(for: note2))
    }

    // MARK: - Incremental Generation

    private func makeTestVault() throws -> (Vault, URL, URL) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("test-incr-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let yaml = """
        title: Test Site
        domain: https://example.com
        author:
          name: Tester
        collections:
          - id: blog
            name: Blog
            icon: doc.text
            description: Blog posts
        """
        try yaml.write(to: tmp.appendingPathComponent("maho.yaml"), atomically: true, encoding: .utf8)

        let blogDir = tmp.appendingPathComponent("blog")
        try fm.createDirectory(at: blogDir, withIntermediateDirectories: true)

        let publicNote = """
        ---
        title: Hello
        tags: []
        created: 2025-01-01
        updated: 2025-01-02
        public: true
        slug: hello
        ---

        # Hello

        Content here.
        """
        try publicNote.write(to: blogDir.appendingPathComponent("001-hello.md"), atomically: true, encoding: .utf8)

        let outputDir = fm.temporaryDirectory.appendingPathComponent("test-output-\(UUID().uuidString)")
        return (Vault(path: tmp.path), outputDir, tmp)
    }

    @Test func incrementalSkipsUnchangedNotes() throws {
        let (vault, outputDir, tmpDir) = try makeTestVault()
        defer { cleanup(outputDir); cleanup(tmpDir) }

        let config = SiteConfig(title: "Test", domain: "https://example.com", author: "Tester")
        let gen = SiteGenerator(vault: vault, config: config)

        // First generation with empty manifest
        let first = try gen.generateIncremental(to: outputDir.path, manifest: PublishManifest())
        #expect(first.result.generated > 0)
        #expect(first.result.skipped == 0)
        #expect(first.manifest.entries.count == 1)

        // Second generation with same manifest — note should be skipped
        let second = try gen.generateIncremental(to: outputDir.path, manifest: first.manifest)
        #expect(second.result.skipped == 1)
        // Shared pages (collection index, site index, RSS) are always regenerated
        #expect(second.result.generated >= 3)
    }

    @Test func incrementalRegeneratesChangedNotes() throws {
        let (vault, outputDir, tmpDir) = try makeTestVault()
        defer { cleanup(outputDir); cleanup(tmpDir) }

        let config = SiteConfig(title: "Test", domain: "https://example.com", author: "Tester")
        let gen = SiteGenerator(vault: vault, config: config)

        // First generation
        let first = try gen.generateIncremental(to: outputDir.path, manifest: PublishManifest())

        // Modify the note
        let notePath = tmpDir.appendingPathComponent("blog/001-hello.md")
        let updatedNote = """
        ---
        title: Hello
        tags: []
        created: 2025-01-01
        updated: 2025-01-03
        public: true
        slug: hello
        ---

        # Hello

        Updated content here!
        """
        try updatedNote.write(to: notePath, atomically: true, encoding: .utf8)

        // Second generation — should regenerate
        let second = try gen.generateIncremental(to: outputDir.path, manifest: first.manifest)
        #expect(second.result.skipped == 0)
        // 1 note + shared pages
        #expect(second.result.generated >= 4)
    }

    @Test func incrementalRemovesDeletedNotes() throws {
        let (vault, outputDir, tmpDir) = try makeTestVault()
        defer { cleanup(outputDir); cleanup(tmpDir) }

        let config = SiteConfig(title: "Test", domain: "https://example.com", author: "Tester")
        let gen = SiteGenerator(vault: vault, config: config)

        // First generation
        let first = try gen.generateIncremental(to: outputDir.path, manifest: PublishManifest())

        // Verify HTML exists
        let htmlPath = outputDir.appendingPathComponent("c/blog/hello.html")
        #expect(FileManager.default.fileExists(atPath: htmlPath.path))

        // Delete the note file
        try FileManager.default.removeItem(at: tmpDir.appendingPathComponent("blog/001-hello.md"))

        // Second generation — should remove stale HTML
        let second = try gen.generateIncremental(to: outputDir.path, manifest: first.manifest)
        #expect(second.manifest.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: htmlPath.path))
    }

    @Test func forceRegeneratesAll() throws {
        let (vault, outputDir, tmpDir) = try makeTestVault()
        defer { cleanup(outputDir); cleanup(tmpDir) }

        let config = SiteConfig(title: "Test", domain: "https://example.com", author: "Tester")
        let gen = SiteGenerator(vault: vault, config: config)

        // Generate with a manifest that already has the note (simulating cached state)
        let notes = try vault.allNotes()
        let publicNotes = notes.filter { $0.isPublic && !$0.draft }
        var prebuiltManifest = PublishManifest()
        for note in publicNotes {
            prebuiltManifest.entries[note.relativePath] = PublishManifest.ManifestEntry(
                contentHash: PublishManifest.contentHash(for: note),
                slug: note.slug ?? makeSlug(from: note.title),
                collection: note.collection,
                generatedAt: "2025-01-01T00:00:00Z"
            )
        }

        // Force mode (full rebuild) should regenerate everything
        let result = try gen.generate(to: outputDir.path)
        // 1 note + 1 collection index + 1 site index + 1 RSS
        #expect(result.generated == 4)
        #expect(result.errors == 0)
    }

    // MARK: - Single Note Publish (frontmatter update)

    @Test func setFrontmatterPublicTrue() throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }

        let notePath = tmp.appendingPathComponent("note.md")
        let content = """
        ---
        title: Test
        public: false
        updated: 2025-01-01
        ---

        Content
        """
        try content.write(to: notePath, atomically: true, encoding: .utf8)

        try setFrontmatterPublic(filePath: notePath.path, isPublic: true)

        let updated = try String(contentsOf: notePath, encoding: .utf8)
        #expect(updated.contains("public: true"))
        #expect(!updated.contains("public: false"))
    }

    @Test func setFrontmatterPublicFalse() throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }

        let notePath = tmp.appendingPathComponent("note.md")
        let content = """
        ---
        title: Test
        public: true
        updated: 2025-01-01
        ---

        Content
        """
        try content.write(to: notePath, atomically: true, encoding: .utf8)

        try setFrontmatterPublic(filePath: notePath.path, isPublic: false)

        let updated = try String(contentsOf: notePath, encoding: .utf8)
        #expect(updated.contains("public: false"))
        #expect(!updated.contains("public: true"))
    }

    // MARK: - Unpublish removes from manifest

    @Test func unpublishRemovesFromManifest() throws {
        let tmp = try makeTempDir()
        defer { cleanup(tmp) }

        let outputDir = tmp.appendingPathComponent("_site/c/blog")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try "html".write(to: outputDir.appendingPathComponent("test.html"), atomically: true, encoding: .utf8)

        var manifest = PublishManifest()
        manifest.entries["blog/001-test.md"] = PublishManifest.ManifestEntry(
            contentHash: "abc",
            slug: "test",
            collection: "blog",
            generatedAt: "2025-01-01T00:00:00Z"
        )

        // Simulate unpublish: remove entry + HTML
        let entry = manifest.entries["blog/001-test.md"]!
        let htmlPath = tmp.appendingPathComponent("_site/c/\(entry.collection)/\(entry.slug).html")
        try? FileManager.default.removeItem(at: htmlPath)
        manifest.entries.removeValue(forKey: "blog/001-test.md")

        #expect(manifest.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: htmlPath.path))
    }

    // MARK: - Hash includes all relevant fields

    @Test func hashChangesWithUpdatedTimestamp() {
        let note1 = makeNote(updated: "2025-01-01")
        let note2 = makeNote(updated: "2025-01-02")
        #expect(PublishManifest.contentHash(for: note1) != PublishManifest.contentHash(for: note2))
    }
}
