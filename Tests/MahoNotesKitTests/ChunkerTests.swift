import Testing
import Foundation
@testable import MahoNotesKit

@Suite("Chunker")
struct ChunkerTests {

    @Test func shortNoteReturnsSingleChunk() {
        let chunks = Chunker.chunkNote(title: "My Note", body: "Short body text.")
        #expect(chunks.count == 1)
        #expect(chunks[0].id == 0)
        #expect(chunks[0].text == "My Note: Short body text.")
    }

    @Test func longNoteWithHeadingsSplitsIntoMultipleChunks() {
        let body = """
        Intro paragraph that has some content to start things off.

        # Section One
        Content of section one which has meaningful text.

        # Section Two
        Content of section two which also has meaningful text.
        """ + String(repeating: " padding", count: 60)

        let chunks = Chunker.chunkNote(title: "Long Note", body: body)
        #expect(chunks.count >= 3)
        #expect(chunks[0].text.hasPrefix("Long Note: "))
        #expect(chunks[1].text.contains("Long Note — Section One: "))
        #expect(chunks[2].text.contains("Long Note — Section Two: "))
    }

    @Test func frontmatterIsStripped() {
        let body = """
        ---
        title: Test
        tags: [a, b]
        ---
        Actual body content here.
        """
        let chunks = Chunker.chunkNote(title: "Test", body: body)
        #expect(chunks.count == 1)
        #expect(!chunks[0].text.contains("tags:"))
        #expect(chunks[0].text.contains("Actual body content"))
    }

    @Test func emptyBodyReturnsOneChunk() {
        let chunks = Chunker.chunkNote(title: "Empty", body: "")
        #expect(chunks.count == 1)
        #expect(chunks[0].text == "Empty")
    }

    @Test func emptyHeadingSectionsAreSkipped() {
        let body = String(repeating: "x", count: 600) + "\n# Empty Section\n\n# Real Section\nContent here."
        let chunks = Chunker.chunkNote(title: "T", body: body)
        // "Empty Section" has no content, should be skipped
        let emptyChunk = chunks.first { $0.text.contains("Empty Section") }
        #expect(emptyChunk == nil)
    }
}
