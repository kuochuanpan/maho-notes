import Testing
import Foundation
import Yams
@testable import MahoNotesKit

@Suite("YAMLFormat")
struct YAMLFormatTests {
    /// Whatever `scalar` writes after `key: ` must load back as the same string.
    @Test(arguments: [
        "Hello World", "Plan: Q4", "# not a comment", "a #b", "true", "null", "2024", "3.14",
        "2026-01-02", "[brackets]", "{braces}", "- dash", "it's", "say \"hi\"", "back\\slash",
        "trailing ", " leading", "", "tab\there", "line\nbreak", "漢字: かんじ", "@handle", "*star",
        "&anchor", "!bang", "%percent", "key: value: again", "~", "yes", "No", "0x1F", "1e5",
    ])
    func scalarRoundTrips(_ value: String) throws {
        let yaml = "k: \(YAMLFormat.scalar(value))"
        let loaded = try #require(try Yams.load(yaml: yaml) as? [String: Any])
        #expect(loaded["k"] as? String == value, "wrote: \(yaml)")
    }

    @Test func plainStringsStayUnquoted() {
        #expect(YAMLFormat.scalar("Hello World") == "Hello World")
        #expect(YAMLFormat.scalar("kanji-basics.md") == "kanji-basics.md")
        #expect(YAMLFormat.scalar("漢字") == "漢字")
    }

    @Test func ambiguousStringsAreQuoted() {
        #expect(YAMLFormat.scalar("Plan: Q4") == "\"Plan: Q4\"")
        #expect(YAMLFormat.scalar("2024") == "\"2024\"")
        #expect(YAMLFormat.scalar("true") == "\"true\"")
    }

    @Test(arguments: [
        ["swift", "testing"], ["a:b", "c#d"], ["with, comma"], ["[x]", "{y}"], ["N5", "漢字"],
        ["true", "2024"], ["it's", "say \"hi\""], [],
    ])
    func flowSequenceRoundTrips(_ tags: [String]) throws {
        let yaml = "k: \(YAMLFormat.flowSequence(tags))"
        let loaded = try #require(try Yams.load(yaml: yaml) as? [String: Any])
        #expect(loaded["k"] as? [String] == tags, "wrote: \(yaml)")
    }

    @Test func timestampIsGregorianWithOffset() throws {
        let stamp = noteTimestamp(Date(timeIntervalSince1970: 1_800_000_000))
        // 2027-01-15 in every time zone; the format is fixed regardless of the user's calendar.
        #expect(stamp.range(of: #"^2027-01-1[45]T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$"#, options: .regularExpression) != nil)
    }
}

@Suite("FrontmatterDocument")
struct FrontmatterDocumentTests {
    private let sample = """
        ---
        title: Block
        tags:
          - one
          - two
        created: 2026-01-02T03:04:05+08:00
        description: "keep: me"
        ---

        # Block

        body

        """

    @Test func untouchedDocumentRendersIdentically() {
        for content in [
            sample,
            "---\ntitle: A\n---",
            "---\ntitle: A\n---\n",
            "---\ntitle: A\n---\nbody right after",
            "---\n---\n",
            "no frontmatter at all\n",
            "",
            "\u{FEFF}---\ntitle: BOM\n---\n\nbody\n",
            "---\r\ntitle: CRLF\r\n---\r\n\r\nbody\r\n",
            "---  \ntitle: Trailing spaces on the delimiters\n--- \nbody\n",
            "---\r\ntitle: Mixed endings\n---\nbody\n",
            "\n\n---\ntitle: Blank lines first\n---\nbody\n",
            "---\nIntro prose between two rules.\n---\nRest.\n",
            "---\n  title: Indented\n---\nbody\n",
        ] {
            #expect(FrontmatterDocument(content).rendered() == content)
        }
    }

    @Test func setReplacesOnlyThatKey() throws {
        var doc = FrontmatterDocument(sample)
        doc.set("title", string: "New: title")
        let out = doc.rendered()
        #expect(out.contains("title: \"New: title\"\n"))
        // Everything else is byte-for-byte what it was.
        #expect(out.contains("tags:\n  - one\n  - two\n"))
        #expect(out.contains("created: 2026-01-02T03:04:05+08:00\n"))
        #expect(out.contains("description: \"keep: me\"\n"))
        #expect(out.hasSuffix("---\n\n# Block\n\nbody\n"))
    }

    @Test func setReplacesWholeBlockValue() throws {
        var doc = FrontmatterDocument(sample)
        doc.set("tags", strings: ["one", "two", "three"])
        let out = doc.rendered()
        #expect(out.contains("tags: [one, two, three]\ncreated:"))
        #expect(!out.contains("  - one"))
        #expect(try doc.yaml()["tags"] as? [String] == ["one", "two", "three"])
    }

    @Test func zeroIndentedListIsOneBlock() throws {
        var doc = FrontmatterDocument("---\ntags:\n- a\n- b\ntitle: T\n---\n")
        doc.set("tags", strings: ["c"])
        #expect(doc.rendered() == "---\ntags: [c]\ntitle: T\n---\n")
    }

    @Test func setAppendsNewKeyAndRemoveDeletesIt() throws {
        var doc = FrontmatterDocument(sample)
        doc.set("public", bool: true)
        doc.set("order", int: 3)
        #expect(doc.rendered().contains("description: \"keep: me\"\npublic: true\norder: 3\n---\n"))
        // Edits keep the delimiter lines as written.
        var spaced = FrontmatterDocument("---  \ntitle: T\n--- \nbody\n")
        spaced.set("public", bool: true)
        #expect(spaced.rendered() == "---  \ntitle: T\npublic: true\n--- \nbody\n")
        let removedOrder = doc.remove("order")
        let removedAgain = doc.remove("order")
        let removedTags = doc.remove("tags")
        #expect(removedOrder)
        #expect(!removedAgain)
        #expect(removedTags)
        #expect(!doc.rendered().contains("- one"))
        #expect(try doc.yaml()["public"] as? Bool == true)
    }

    @Test func keyPrefixDoesNotMatchLongerKey() {
        var doc = FrontmatterDocument("---\ntitles: other\ntitle: T\n---\n")
        doc.set("title", string: "New")
        #expect(doc.rendered() == "---\ntitles: other\ntitle: New\n---\n")
    }

    @Test func repeatedEditsNeverFuseBodyOntoDelimiter() throws {
        // Regression: the writer used to drop the line break after the closing `---`,
        // so a second edit produced `---# Title` and the frontmatter was lost.
        var content = "---\ntitle: T\n---\n# Heading\n"
        for i in 0..<5 {
            var doc = FrontmatterDocument(content)
            doc.set("order", int: i)
            content = doc.rendered()
        }
        #expect(content == "---\ntitle: T\norder: 4\n---\n# Heading\n")
        #expect(splitFrontmatter(content).yaml == "title: T\norder: 4")
    }

    @Test func addsFrontmatterToPlainFile() throws {
        var doc = FrontmatterDocument("Just text\n")
        #expect(!doc.hasFrontmatter)
        doc.set("title", string: "Now titled")
        #expect(doc.rendered() == "---\ntitle: Now titled\n---\n\nJust text\n")
    }

    @Test func invalidYAMLIsReported() {
        let doc = FrontmatterDocument("---\ntitle: a: b\n---\n")
        #expect(throws: FrontmatterError.self) { try doc.yaml() }
    }

    @Test func crlfFileKeepsItsLineEndings() throws {
        var doc = FrontmatterDocument("---\r\ntitle: Old\r\ntags: [a]\r\n---\r\n\r\nbody\r\n")
        #expect(doc.hasFrontmatter)
        doc.set("title", string: "New")
        #expect(doc.rendered() == "---\r\ntitle: New\r\ntags: [a]\r\n---\r\n\r\nbody\r\n")
        #expect(try doc.yaml()["title"] as? String == "New")
    }

    @Test func splitFrontmatterReadsCRLF() {
        let (yaml, body) = splitFrontmatter("---\r\ntitle: Win\r\n---\r\nbody\r\n")
        #expect(yaml?.contains("title: Win") == true)
        #expect(body == "body\r\n")
    }

    @Test func setFrontmatterPublicKeepsBodySeparation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("n.md").path
        try "---\ntitle: T\npublic: false\n---\n\n# T\n".write(toFile: file, atomically: true, encoding: .utf8)

        // Publish then unpublish, twice over — the note must come back unchanged.
        for flag in [true, false, true, false] {
            try setFrontmatterPublic(filePath: file, isPublic: flag)
        }
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "---\ntitle: T\npublic: false\n---\n\n# T\n")
    }
}
