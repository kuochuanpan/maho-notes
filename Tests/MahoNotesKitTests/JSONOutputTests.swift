import Testing
import Foundation
@testable import MahoNotesKit

@Suite("JSON Output")
struct JSONOutputTests {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private func encodeToJSON<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try encoder.encode(value)
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj as! [String: Any]
    }

    // MARK: - Note

    @Test func noteEncodesToValidJSON() throws {
        let note = Note(
            relativePath: "journal/2024-01-01.md",
            title: "My Note",
            tags: ["swift", "test"],
            created: "2024-01-01T00:00:00Z",
            updated: "2024-01-01T00:00:00Z",
            isPublic: true,
            slug: "my-note",
            author: "Tester",
            draft: false,
            order: 1,
            series: nil,
            body: "Hello world"
        )
        let json = try encodeToJSON(note)
        #expect(json["title"] as? String == "My Note")
        #expect(json["collection"] as? String == "journal")
        #expect((json["tags"] as? [String])?.count == 2)
    }

    @Test func noteArrayEncodesToValidJSON() throws {
        let notes: [Note] = []
        let data = try encoder.encode(notes)
        let arr = try JSONSerialization.jsonObject(with: data) as? [Any]
        #expect(arr != nil)
        #expect(arr?.count == 0)
    }

    // MARK: - Collection

    @Test func collectionEncodesToValidJSON() throws {
        let coll = Collection(id: "journal", name: "Journal", icon: "book", description: "Daily notes")
        let json = try encodeToJSON(coll)
        #expect(json["id"] as? String == "journal")
        #expect(json["name"] as? String == "Journal")
    }

    // MARK: - IndexStats

    @Test func indexStatsEncodesToValidJSON() throws {
        let stats = IndexStats(added: 5, updated: 2, deleted: 1, total: 10)
        let json = try encodeToJSON(stats)
        #expect(json["added"] as? Int == 5)
        #expect(json["updated"] as? Int == 2)
        #expect(json["deleted"] as? Int == 1)
        #expect(json["total"] as? Int == 10)
    }

    // MARK: - SyncResult

    @Test func syncResultEncodesToValidJSON() throws {
        let result = SyncResult(cloned: false, pulled: true, pushed: false, conflictFiles: [], message: "Up to date")
        let json = try encodeToJSON(result)
        #expect(json["pulled"] as? Bool == true)
        #expect(json["pushed"] as? Bool == false)
        #expect(json["message"] as? String == "Up to date")
        #expect((json["conflictFiles"] as? [String])?.isEmpty == true)
    }

    @Test func syncResultWithConflictsEncodesToValidJSON() throws {
        let result = SyncResult(cloned: false, pulled: true, pushed: false, conflictFiles: ["a.md", "b.md"], message: "Conflicts found")
        let json = try encodeToJSON(result)
        #expect((json["conflictFiles"] as? [String])?.count == 2)
    }
}
