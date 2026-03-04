import Testing
@testable import MahoNotesKit

@Suite("makeSlug")
struct MakeSlugTests {
    @Test func simpleEnglish() {
        #expect(makeSlug(from: "Hello World") == "hello-world")
    }

    @Test func removesSpecialCharacters() {
        #expect(makeSlug(from: "What's Up?") == "whats-up")
    }

    @Test func multipleSpaces() {
        #expect(makeSlug(from: "one  two   three") == "one--two---three")
    }

    @Test func emptyString() {
        #expect(makeSlug(from: "") == "")
    }

    @Test func alreadySlug() {
        #expect(makeSlug(from: "already-a-slug") == "already-a-slug")
    }

    @Test func numbersPreserved() {
        #expect(makeSlug(from: "Section 42") == "section-42")
    }
}
