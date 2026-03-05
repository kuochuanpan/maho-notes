import Foundation

/// A merged search result from hybrid (keyword + semantic) search.
public struct HybridSearchResult: Sendable {
    public let path: String
    public let title: String
    public let tags: [String]
    public let snippet: String
    public let rrfScore: Double
    public let sources: Set<String> // "fts", "vec"
}

/// Reciprocal Rank Fusion: merge two ranked result lists.
public enum HybridSearch {
    /// RRF constant (standard default = 60).
    private static let k: Double = 60

    public static func merge(
        ftsResults: [SearchResult],
        vectorResults: [VectorSearchResult],
        limit: Int = 10
    ) -> [HybridSearchResult] {
        var scoresByPath: [String: Double] = [:]
        var metaByPath: [String: (title: String, tags: [String], snippet: String)] = [:]
        var sourcesByPath: [String: Set<String>] = [:]

        // FTS ranked results
        for (rank, r) in ftsResults.enumerated() {
            let rrfContrib = 1.0 / (k + Double(rank + 1))
            scoresByPath[r.path, default: 0] += rrfContrib
            metaByPath[r.path] = (title: r.title, tags: r.tags, snippet: r.snippet)
            sourcesByPath[r.path, default: []].insert("fts")
        }

        // Vector ranked results
        for (rank, r) in vectorResults.enumerated() {
            let rrfContrib = 1.0 / (k + Double(rank + 1))
            scoresByPath[r.path, default: 0] += rrfContrib
            if metaByPath[r.path] == nil {
                metaByPath[r.path] = (title: "", tags: [], snippet: r.chunkText)
            }
            sourcesByPath[r.path, default: []].insert("vec")
        }

        return scoresByPath
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (path, score) in
                let meta = metaByPath[path] ?? (title: "", tags: [], snippet: "")
                let sources = sourcesByPath[path] ?? []
                return HybridSearchResult(
                    path: path,
                    title: meta.title,
                    tags: meta.tags,
                    snippet: meta.snippet,
                    rrfScore: score,
                    sources: sources
                )
            }
    }
}
