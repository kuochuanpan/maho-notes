import Testing
@testable import MahoNotesKit

@Suite("MarkdownHTMLRenderer")
struct MarkdownRenderTests {

    let renderer = MarkdownHTMLRenderer()

    // MARK: - Footnotes

    @Test func footnoteBasic() {
        let md = """
        This has a footnote[^1].

        [^1]: First footnote content.
        """
        let html = renderer.render(md)
        #expect(html.contains("fnref-1"))
        #expect(html.contains("fn-1"))
        #expect(html.contains("class=\"footnotes\""))
        #expect(html.contains("footnote-backref"))
        #expect(html.contains("First footnote content."))
    }

    @Test func footnoteMultiple() {
        let md = """
        First ref[^a] and second ref[^b].

        [^a]: Alpha note.
        [^b]: Beta note.
        """
        let html = renderer.render(md)
        // Both should be numbered in order of appearance
        #expect(html.contains("fnref-a"))
        #expect(html.contains("fnref-b"))
        #expect(html.contains("fn-a"))
        #expect(html.contains("fn-b"))
        #expect(html.contains("Alpha note."))
        #expect(html.contains("Beta note."))
    }

    @Test func footnoteNoDefinition() {
        let md = "Text with orphan ref[^orphan] stays as-is."
        let html = renderer.render(md)
        // Should NOT be converted to a footnote link
        #expect(!html.contains("fnref-orphan"))
        #expect(html.contains("[^orphan]") || html.contains("orphan"))
    }

    @Test func noFootnotes() {
        let md = "Just plain text, nothing special."
        let html = renderer.render(md)
        #expect(!html.contains("class=\"footnotes\""))
    }

    // MARK: - Mermaid

    @Test func mermaidCodeBlock() {
        let md = """
        ```mermaid
        graph LR
            A --> B
        ```
        """
        let html = renderer.render(md)
        #expect(html.contains("<div class=\"mermaid\">"))
        #expect(html.contains("A --> B"))
        // Should NOT be wrapped in <pre><code>
        #expect(!html.contains("<pre><code"))
    }

    // MARK: - Ruby

    @Test func rubyAnnotation() {
        let md = "The word {漢字|かんじ} means kanji."
        let html = renderer.render(md)
        #expect(html.contains("<ruby>"))
        #expect(html.contains("<rt>かんじ</rt>"))
    }

    // MARK: - Code block protection

    @Test func rubyInsideCodeBlockNotTransformed() {
        let md = """
        ```markdown
        {漢字|かんじ}
        ```
        """
        let html = renderer.render(md)
        // Should NOT contain <ruby> — it's inside a code block
        #expect(!html.contains("<ruby>"))
        // The raw text should appear as-is (escaped)
        #expect(html.contains("漢字") || html.contains("かんじ"))
    }

    @Test func footnoteInsideCodeBlockNotTransformed() {
        let md = """
        ```markdown
        Text with a footnote[^1].

        [^1]: This is a footnote.
        ```
        """
        let html = renderer.render(md)
        // Should NOT contain footnote HTML
        #expect(!html.contains("class=\"footnotes\""))
        #expect(!html.contains("fnref-"))
    }

    @Test func rubyInsideInlineCodeNotTransformed() {
        let md = "Use `{漢字|かんじ}` for furigana."
        let html = renderer.render(md)
        // The inline code should preserve the raw syntax
        #expect(!html.contains("<ruby>"))
    }

    @Test func mathInsideCodeBlockNotTransformed() {
        let md = """
        ```
        $E = mc^2$
        ```
        """
        let html = renderer.render(md)
        #expect(!html.contains("math-inline"))
    }

    // MARK: - Math

    @Test func inlineMath() {
        let md = "Einstein's $E = mc^2$ is famous."
        let html = renderer.render(md)
        #expect(html.contains("math-inline"))
        #expect(html.contains("E = mc^2"))
    }

    @Test func displayMath() {
        let md = """
        $$
        \\int_0^1 x dx = \\frac{1}{2}
        $$
        """
        let html = renderer.render(md)
        #expect(html.contains("math-block"))
    }
}
