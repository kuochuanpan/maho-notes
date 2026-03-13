import Foundation
import Testing
@testable import MahoNotesKit

@Suite("Note")
struct NoteTests {
    @Test func collectionInferredFromPath() {
        let note = Note(
            relativePath: "japanese/grammar/001-test.md",
            title: "Test", tags: [], created: "", updated: "",
            isPublic: false, slug: nil, author: nil, draft: false,
            order: nil, series: nil, body: ""
        )
        #expect(note.collection == "japanese")
    }

    @Test func collectionEmptyForRootFile() {
        let note = Note(
            relativePath: "orphan.md",
            title: "Orphan", tags: [], created: "", updated: "",
            isPublic: false, slug: nil, author: nil, draft: false,
            order: nil, series: nil, body: ""
        )
        #expect(note.collection == "")
    }

    @Test func codableRoundTrip() throws {
        let note = Note(
            relativePath: "japanese/vocab/001-star.md",
            title: "Star", tags: ["N5", "astronomy"], created: "2026-03-03",
            updated: "2026-03-04", isPublic: true, slug: "star",
            author: "maho", draft: false, order: 1, series: "Basics",
            body: "# Star\n\nContent."
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(note)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Note.self, from: data)

        #expect(decoded.title == "Star")
        #expect(decoded.collection == "japanese")
        #expect(decoded.tags == ["N5", "astronomy"])
        #expect(decoded.isPublic == true)
        #expect(decoded.slug == "star")
        #expect(decoded.order == 1)
        #expect(decoded.series == "Basics")
    }
}
