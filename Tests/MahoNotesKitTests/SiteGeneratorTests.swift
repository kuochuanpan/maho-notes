import Testing
import Foundation
@testable import MahoNotesKit

@Suite("Site Generator")
struct SiteGeneratorTests {
    private let renderer = MarkdownHTMLRenderer()

    // MARK: - Markdown Rendering

    @Test func headings() {
        let html = renderer.render("# Hello\n## World")
        #expect(html.contains("<h1>Hello</h1>"))
        #expect(html.contains("<h2>World</h2>"))
    }

    @Test func boldAndItalic() {
        let html = renderer.render("**bold** and *italic*")
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<em>italic</em>"))
    }

    @Test func links() {
        let html = renderer.render("[click](https://example.com)")
        #expect(html.contains("<a href=\"https://example.com\">click</a>"))
    }

    @Test func codeBlocks() {
        let html = renderer.render("```swift\nlet x = 1\n```")
        #expect(html.contains("<pre><code class=\"language-swift\">"))
        #expect(html.contains("let x = 1"))
    }

    @Test func inlineCode() {
        let html = renderer.render("Use `print()`")
        #expect(html.contains("<code>print()</code>"))
    }

    @Test func tables() {
        let md = """
        | A | B |
        |---|---|
        | 1 | 2 |
        """
        let html = renderer.render(md)
        #expect(html.contains("<table>"))
        #expect(html.contains("<th>A</th>"))
        #expect(html.contains("<td>1</td>"))
    }

    @Test func images() {
        let html = renderer.render("![alt text](image.png)")
        #expect(html.contains("<img src=\"image.png\" alt=\"alt text\">"))
    }

    @Test func strikethrough() {
        let html = renderer.render("~~deleted~~")
        #expect(html.contains("<del>deleted</del>"))
    }

    // MARK: - Ruby Annotations

    @Test func rubyAnnotation() {
        let html = renderer.render("{漢字|かんじ}")
        #expect(html.contains("<ruby><rb>漢字</rb><rp>(</rp><rt>かんじ</rt><rp>)</rp></ruby>"))
    }

    @Test func multipleRubyAnnotations() {
        let html = renderer.render("{東京|とうきょう}は{日本|にほん}の{首都|しゅと}")
        #expect(html.contains("<ruby><rb>東京</rb>"))
        #expect(html.contains("<ruby><rb>日本</rb>"))
        #expect(html.contains("<ruby><rb>首都</rb>"))
    }

    // MARK: - Admonitions

    @Test func admonitionTip() {
        let md = """
        > [!tip]
        > This is a tip
        """
        let html = renderer.render(md)
        #expect(html.contains("admonition admonition-tip"))
        #expect(html.contains("Tip"))
    }

    @Test func admonitionWarning() {
        let md = """
        > [!warning]
        > Be careful
        """
        let html = renderer.render(md)
        #expect(html.contains("admonition admonition-warning"))
        #expect(html.contains("Warning"))
    }

    // MARK: - Math

    @Test func inlineMath() {
        let html = renderer.render("The formula $E=mc^2$ is famous")
        #expect(html.contains("<span class=\"math-inline\">"))
        #expect(html.contains("E=mc^2"))
    }

    @Test func displayMath() {
        let html = renderer.render("$$\nx^2 + y^2 = z^2\n$$")
        #expect(html.contains("<div class=\"math-block\">"))
    }

    // MARK: - Mermaid

    @Test func mermaidCodeBlock() {
        let md = """
        ```mermaid
        graph TD
            A --> B
        ```
        """
        let html = renderer.render(md)
        #expect(html.contains("<div class=\"mermaid\">"))
        #expect(!html.contains("language-mermaid"))
    }

    // MARK: - Reading Time

    @Test func readingTime() {
        // 200 words = 1 min
        let shortText = Array(repeating: "word", count: 100).joined(separator: " ")
        #expect(SiteGenerator.readingTime(for: shortText) == 1)

        let longText = Array(repeating: "word", count: 600).joined(separator: " ")
        #expect(SiteGenerator.readingTime(for: longText) == 3)
    }

    // MARK: - Site Generation (Integration)

    private func makeTestVault() throws -> (Vault, URL, URL) {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("test-site-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        // maho.yaml
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

        // Create blog collection
        let blogDir = tmp.appendingPathComponent("blog")
        try fm.createDirectory(at: blogDir, withIntermediateDirectories: true)

        // Public note
        let publicNote = """
        ---
        title: Public Post
        tags: [swift, testing]
        created: 2025-01-01
        updated: 2025-01-02
        public: true
        slug: public-post
        author: tester
        ---

        # Public Post

        This is a **public** post with some content.
        """
        try publicNote.write(to: blogDir.appendingPathComponent("001-public-post.md"), atomically: true, encoding: .utf8)

        // Private note
        let privateNote = """
        ---
        title: Private Post
        tags: [secret]
        created: 2025-01-01
        updated: 2025-01-02
        public: false
        ---

        Private content here.
        """
        try privateNote.write(to: blogDir.appendingPathComponent("002-private-post.md"), atomically: true, encoding: .utf8)

        // Draft note (public but draft)
        let draftNote = """
        ---
        title: Draft Post
        tags: []
        created: 2025-01-01
        updated: 2025-01-02
        public: true
        draft: true
        ---

        Draft content.
        """
        try draftNote.write(to: blogDir.appendingPathComponent("003-draft.md"), atomically: true, encoding: .utf8)

        let outputDir = fm.temporaryDirectory.appendingPathComponent("test-output-\(UUID().uuidString)")

        return (Vault(path: tmp.path), outputDir, tmp)
    }

    private func cleanup(_ urls: URL...) {
        let fm = FileManager.default
        for url in urls {
            try? fm.removeItem(at: url)
        }
    }

    @Test func generatesOnlyPublicNonDraftNotes() throws {
        let (vault, outputDir, tmpDir) = try makeTestVault()
        defer { cleanup(outputDir, tmpDir) }

        let config = SiteConfig(title: "Test", domain: "https://example.com", author: "Tester")
        let generator = SiteGenerator(vault: vault, config: config)
        let result = try generator.generate(to: outputDir.path)

        // 1 public non-draft note + 1 collection index + 1 site index + 1 RSS = 4 generated
        #expect(result.generated == 4)
        #expect(result.skipped == 2) // 1 private + 1 draft
        #expect(result.errors == 0)

        // Public note should exist
        let publicFile = outputDir.appendingPathComponent("c/blog/public-post.html")
        #expect(FileManager.default.fileExists(atPath: publicFile.path))

        // Private note should NOT exist
        let privateFile = outputDir.appendingPathComponent("c/blog/private-post.html")
        #expect(!FileManager.default.fileExists(atPath: privateFile.path))
    }

    @Test func indexPageListsCollections() throws {
        let (vault, outputDir, tmpDir) = try makeTestVault()
        defer { cleanup(outputDir, tmpDir) }

        let config = SiteConfig(title: "Test Site", domain: "https://example.com", author: "Tester")
        let generator = SiteGenerator(vault: vault, config: config)
        _ = try generator.generate(to: outputDir.path)

        let indexPath = outputDir.appendingPathComponent("index.html")
        let indexHTML = try String(contentsOf: indexPath, encoding: .utf8)
        #expect(indexHTML.contains("Test Site"))
        #expect(indexHTML.contains("blog"))
        #expect(indexHTML.contains("Public Post"))
    }

    @Test func collectionPageListsNotes() throws {
        let (vault, outputDir, tmpDir) = try makeTestVault()
        defer { cleanup(outputDir, tmpDir) }

        let config = SiteConfig(title: "Test Site", domain: "https://example.com", author: "Tester")
        let generator = SiteGenerator(vault: vault, config: config)
        _ = try generator.generate(to: outputDir.path)

        let colPath = outputDir.appendingPathComponent("c/blog/index.html")
        let colHTML = try String(contentsOf: colPath, encoding: .utf8)
        #expect(colHTML.contains("Blog"))
        #expect(colHTML.contains("Public Post"))
        #expect(!colHTML.contains("Private Post"))
    }

    @Test func rssFeedGenerated() throws {
        let (vault, outputDir, tmpDir) = try makeTestVault()
        defer { cleanup(outputDir, tmpDir) }

        let config = SiteConfig(title: "Test Site", domain: "https://example.com", author: "Tester")
        let generator = SiteGenerator(vault: vault, config: config)
        _ = try generator.generate(to: outputDir.path)

        let feedPath = outputDir.appendingPathComponent("feed.xml")
        let feedXML = try String(contentsOf: feedPath, encoding: .utf8)
        #expect(feedXML.contains("<rss version=\"2.0\">"))
        #expect(feedXML.contains("Public Post"))
        #expect(feedXML.contains("https://example.com"))
        #expect(!feedXML.contains("Private Post"))
    }

    @Test func notePageHasOGTags() throws {
        let (vault, outputDir, tmpDir) = try makeTestVault()
        defer { cleanup(outputDir, tmpDir) }

        let config = SiteConfig(title: "Test Site", domain: "https://example.com", author: "Tester")
        let generator = SiteGenerator(vault: vault, config: config)
        _ = try generator.generate(to: outputDir.path)

        let notePath = outputDir.appendingPathComponent("c/blog/public-post.html")
        let noteHTML = try String(contentsOf: notePath, encoding: .utf8)
        #expect(noteHTML.contains("og:title"))
        #expect(noteHTML.contains("og:description"))
        #expect(noteHTML.contains("og:url"))
        #expect(noteHTML.contains("og:type"))
    }

    @Test func notePageHasReadingTime() throws {
        let (vault, outputDir, tmpDir) = try makeTestVault()
        defer { cleanup(outputDir, tmpDir) }

        let config = SiteConfig(title: "Test Site", domain: "https://example.com", author: "Tester")
        let generator = SiteGenerator(vault: vault, config: config)
        _ = try generator.generate(to: outputDir.path)

        let notePath = outputDir.appendingPathComponent("c/blog/public-post.html")
        let noteHTML = try String(contentsOf: notePath, encoding: .utf8)
        #expect(noteHTML.contains("min read"))
    }

    @Test func notePageIsValidHTML5() throws {
        let (vault, outputDir, tmpDir) = try makeTestVault()
        defer { cleanup(outputDir, tmpDir) }

        let config = SiteConfig(title: "Test Site", domain: "https://example.com", author: "Tester")
        let generator = SiteGenerator(vault: vault, config: config)
        _ = try generator.generate(to: outputDir.path)

        let notePath = outputDir.appendingPathComponent("c/blog/public-post.html")
        let noteHTML = try String(contentsOf: notePath, encoding: .utf8)
        #expect(noteHTML.contains("<!DOCTYPE html>"))
        #expect(noteHTML.contains("<html lang=\"en\">"))
        #expect(noteHTML.contains("<meta charset=\"utf-8\">"))
        #expect(noteHTML.contains("<meta name=\"viewport\""))
    }
}
