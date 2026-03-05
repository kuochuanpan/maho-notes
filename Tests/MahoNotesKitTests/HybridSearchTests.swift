import Testing
import Foundation
@testable import MahoNotesKit

@Suite("HybridSearch")
struct HybridSearchTests {

    @Test func rrfMergesCombinesRankedLists() {
        let ftsResults: [SearchResult] = [
            SearchResult(path: "a.md", title: "A", tags: [], snippet: "snip A", rank: -5.0),
            SearchResult(path: "b.md", title: "B", tags: [], snippet: "snip B", rank: -3.0),
            SearchResult(path: "c.md", title: "C", tags: [], snippet: "snip C", rank: -1.0),
        ]

        let vecResults: [VectorSearchResult] = [
            VectorSearchResult(path: "b.md", chunkText: "vec B", score: 0.9, chunkId: 0),
            VectorSearchResult(path: "d.md", chunkText: "vec D", score: 0.8, chunkId: 0),
            VectorSearchResult(path: "a.md", chunkText: "vec A", score: 0.7, chunkId: 0),
        ]

        let merged = HybridSearch.merge(ftsResults: ftsResults, vectorResults: vecResults)

        // a.md and b.md appear in both lists → highest RRF scores
        #expect(merged.count == 4)
        let paths = merged.map(\.path)
        // a.md: fts rank 1 → 1/61, vec rank 3 → 1/63
        // b.md: fts rank 2 → 1/62, vec rank 1 → 1/61
        // Both should be at the top
        #expect(paths[0] == "b.md" || paths[0] == "a.md")
        #expect(paths[1] == "b.md" || paths[1] == "a.md")

        // b.md should appear in both sources
        let bResult = merged.first { $0.path == "b.md" }!
        #expect(bResult.sources.contains("fts"))
        #expect(bResult.sources.contains("vec"))

        // d.md only in vec
        let dResult = merged.first { $0.path == "d.md" }!
        #expect(dResult.sources == Set(["vec"]))
    }

    @Test func rrfLimitsResults() {
        let ftsResults = (0..<20).map {
            SearchResult(path: "note-\($0).md", title: "Note \($0)", tags: [], snippet: "", rank: Double(-$0))
        }
        let merged = HybridSearch.merge(ftsResults: ftsResults, vectorResults: [], limit: 5)
        #expect(merged.count == 5)
    }

    @Test func emptyInputsReturnEmpty() {
        let merged = HybridSearch.merge(ftsResults: [], vectorResults: [])
        #expect(merged.isEmpty)
    }

    @Test func ranksAreTracked() {
        let ftsResults: [SearchResult] = [
            SearchResult(path: "a.md", title: "A", tags: [], snippet: "", rank: -5.0),
            SearchResult(path: "b.md", title: "B", tags: [], snippet: "", rank: -3.0),
        ]
        let vecResults: [VectorSearchResult] = [
            VectorSearchResult(path: "b.md", chunkText: "", score: 0.9, chunkId: 0),
            VectorSearchResult(path: "c.md", chunkText: "", score: 0.8, chunkId: 0),
        ]

        let merged = HybridSearch.merge(ftsResults: ftsResults, vectorResults: vecResults)

        let a = merged.first { $0.path == "a.md" }!
        #expect(a.ftsRank == 1)
        #expect(a.vectorRank == nil)

        let b = merged.first { $0.path == "b.md" }!
        #expect(b.ftsRank == 2)
        #expect(b.vectorRank == 1)

        let c = merged.first { $0.path == "c.md" }!
        #expect(c.ftsRank == nil)
        #expect(c.vectorRank == 2)
    }
}
