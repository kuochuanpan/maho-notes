import Foundation
import Testing
@testable import MahoNotesKit

@Suite("FrontmatterParser")
struct FrontmatterParserTests {
    @Test func splitValidFrontmatter() {
        let content = """
        ---
        title: Test
        tags: [a, b]
        ---

        # Body here
        """
        let (yaml, body) = splitFrontmatter(content)
        #expect(yaml != nil)
        #expect(yaml!.contains("title: Test"))
        #expect(body.contains("# Body here"))
    }

    @Test func splitNoFrontmatter() {
        let content = "# Just a heading\n\nSome text."
        let (yaml, body) = splitFrontmatter(content)
        #expect(yaml == nil)
        #expect(body == content)
    }

    @Test func splitUnclosedFrontmatter() {
        let content = "---\ntitle: Test\nNo closing delimiter"
        let (yaml, body) = splitFrontmatter(content)
        #expect(yaml == nil)
        #expect(body == content)
    }

    @Test func parseNoteFromFile() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("test-vault-\(UUID().uuidString)")
        let noteDir = tmp.appendingPathComponent("japanese/grammar")
        try fm.createDirectory(at: noteDir, withIntermediateDirectories: true)

        let noteContent = """
        ---
        title: Test Note
        tags: [N5, grammar]
        created: 2026-03-03T09:00:00-05:00
        updated: 2026-03-03T10:00:00-05:00
        public: false
        author: maho
        series: Basics
        order: 1
        ---

        # Test Note

        Some content here.
        """
        let notePath = noteDir.appendingPathComponent("001-test.md")
        try noteContent.write(to: notePath, atomically: true, encoding: .utf8)

        let note = try parseNote(at: notePath.path, relativeTo: tmp.path)
        #expect(note != nil)
        #expect(note!.title == "Test Note")
        #expect(note!.collection == "japanese")
        #expect(note!.tags == ["N5", "grammar"])
        #expect(note!.author == "maho")
        #expect(note!.series == "Basics")
        #expect(note!.order == 1)
        #expect(note!.relativePath == "japanese/grammar/001-test.md")
        #expect(note!.body.contains("Some content here."))

        try fm.removeItem(at: tmp)
    }

    @Test func parseNoteWithNoTitle() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("test-vault-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let noteContent = """
        ---
        tags: [test]
        ---

        No title field
        """
        let notePath = tmp.appendingPathComponent("note.md")
        try noteContent.write(to: notePath, atomically: true, encoding: .utf8)

        let note = try parseNote(at: notePath.path, relativeTo: tmp.path)
        #expect(note == nil)

        try fm.removeItem(at: tmp)
    }
}
