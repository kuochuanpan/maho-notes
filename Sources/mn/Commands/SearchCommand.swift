import ArgumentParser
import Foundation
import MahoNotesKit

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search notes by text (FTS5 with CJK support)"
    )

    @OptionGroup var vaultOption: VaultOption
    @OptionGroup var outputOption: OutputOption

    @Argument(help: "Search query")
    var query: String

    @Flag(name: .long, help: "Search across all registered vaults (default when --vault is not specified)")
    var all = false

    @Flag(name: .long, help: "Semantic search using vector embeddings")
    var semantic = false

    @Flag(name: .long, help: "Hybrid search combining keyword + semantic (RRF)")
    var hybrid = false

    @Option(name: .long, help: "Maximum number of results")
    var limit: Int = 10

    func validate() throws {
        if limit < 1 {
            throw ValidationError("--limit must be at least 1.")
        }
    }

    func run() async throws {
        let store = VaultStore.shared
        if semantic || hybrid {
            if #available(macOS 15.0, *) {
                // Cross-vault semantic/hybrid: iterate all vaults
                let searchAll = all || vaultOption.vault == nil
                if searchAll, let entries = vaultOption.allVaultEntries(), !entries.isEmpty {
                    for entry in entries {
                        let vault = Vault(path: store.resolvedPath(for: entry))
                        try await runSemanticOrHybrid(vault: vault)
                    }
                } else {
                    try vaultOption.validateVaultExists()
                    let vault = vaultOption.makeVault()
                    try await runSemanticOrHybrid(vault: vault)
                }
            } else {
                throw ValidationError("Semantic search requires macOS 15+")
            }
            return
        }

        // Default to all vaults unless --vault is explicitly specified
        let searchAll = all || vaultOption.vault == nil
        if searchAll, let entries = vaultOption.allVaultEntries(), !entries.isEmpty {
            try runAllVaults(entries: entries)
            return
        }
        // Single-vault search
        try vaultOption.validateVaultExists()
        let vault = vaultOption.makeVault()
        do {
            let results = try ftsSearch(vault: vault)
            outputResults(Array(results.prefix(limit)), vaultName: nil, fts: true)
        } catch {
            FileHandle.standardError.write(
                "⚠️  FTS5 search failed (\(error.localizedDescription)), falling back to substring search.\n"
                    .data(using: .utf8)!
            )
            FileHandle.standardError.write(
                "   Run `mn index --full` to rebuild the search index.\n"
                    .data(using: .utf8)!
            )
            let results = try vault.searchNotes(query: query)
            outputSubstringResults(Array(results.prefix(limit)), vaultName: nil)
        }
    }

    // MARK: - Semantic / Hybrid

    @available(macOS 15.0, *)
    private func runSemanticOrHybrid(vault: Vault) async throws {
        if hybrid {
            // Hybrid: run FTS always, vector if available
            let ftsResults = try ftsSearch(vault: vault)

            if VectorIndex.vectorIndexExists(vaultPath: vault.path),
               let vecIndex = try? VectorIndex(vaultPath: vault.path, skipDimensionCheck: true),
               let modelName = (try? vecIndex.currentModel()) ?? nil,
               let embeddingModel = EmbeddingModel(rawValue: modelName) {
                let provider = SwiftEmbeddingsProvider(model: embeddingModel)
                let queryVector = try await provider.embedQuery(query)
                let vecResults = try vecIndex.search(queryVector: queryVector, limit: 50)
                let ftsTop50 = Array(ftsResults.prefix(50))
                let merged = HybridSearch.merge(ftsResults: ftsTop50, vectorResults: vecResults, limit: limit)
                outputHybridResults(merged)
            } else {
                FileHandle.standardError.write(
                    "⚠️  No vector index found; falling back to keyword search only.\n".data(using: .utf8)!
                )
                outputResults(Array(ftsResults.prefix(limit)), vaultName: nil, fts: true)
            }
            return
        }

        // Semantic only
        guard VectorIndex.vectorIndexExists(vaultPath: vault.path) else {
            throw ValidationError("No vector index found. Run `mn index --model <name>` first.")
        }

        let vecIndex = try VectorIndex(vaultPath: vault.path, skipDimensionCheck: true)
        guard let modelName = try vecIndex.currentModel(),
              let embeddingModel = EmbeddingModel(rawValue: modelName) else {
            throw ValidationError("Could not determine embedding model from vector index.")
        }

        let provider = SwiftEmbeddingsProvider(model: embeddingModel)
        let queryVector = try await provider.embedQuery(query)
        let results = try vecIndex.search(queryVector: queryVector, limit: limit)
        outputVectorResults(results)
    }

    private func outputVectorResults(_ results: [VectorSearchResult]) {
        if outputOption.json {
            let jsonArray = results.map { r -> [String: Any] in
                [
                    "path": r.path,
                    "snippet": r.chunkText,
                    "score": r.score,
                ]
            }
            if let data = try? JSONSerialization.data(withJSONObject: jsonArray, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return
        }

        if results.isEmpty {
            print("No results for: \(query)")
            return
        }

        print("Found \(results.count) result(s) for \"\(query)\" (semantic):\n")
        for result in results {
            print("  \(result.path)  (score: \(String(format: "%.3f", result.score)))")
            if !result.chunkText.isEmpty {
                let snippet = String(result.chunkText.prefix(120))
                print("    … \(snippet)")
            }
            print()
        }
    }

    private func outputHybridResults(_ results: [HybridSearchResult]) {
        if outputOption.json {
            let jsonArray = results.map { r -> [String: Any] in
                var d: [String: Any] = [
                    "path": r.path,
                    "title": r.title,
                    "tags": r.tags,
                    "snippet": r.snippet,
                    "rrf_score": r.rrfScore,
                    "sources": Array(r.sources),
                ]
                if let ftsRank = r.ftsRank { d["fts_rank"] = ftsRank }
                if let vectorRank = r.vectorRank { d["vector_rank"] = vectorRank }
                return d
            }
            if let data = try? JSONSerialization.data(withJSONObject: jsonArray, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return
        }

        if results.isEmpty {
            print("No results for: \(query)")
            return
        }

        print("Found \(results.count) result(s) for \"\(query)\" (hybrid):\n")
        for result in results {
            let sources = result.sources.sorted().joined(separator: "+")
            print("  \(result.path)  [\(sources)]  (rrf: \(String(format: "%.4f", result.rrfScore)))")
            if !result.title.isEmpty {
                let tags = result.tags.isEmpty ? "" : " [\(result.tags.joined(separator: ", "))]"
                print("    \(result.title)\(tags)")
            }
            if !result.snippet.isEmpty {
                print("    … \(String(result.snippet.prefix(120)))")
            }
            print()
        }
    }

    // MARK: - Cross-vault

    private func runAllVaults(entries: [VaultEntry]) throws {
        let store = VaultStore.shared

        // Gather hits from every vault, then keep the best `limit` overall.
        // bm25 ranks are negative, lower is better; substring hits have no rank and go last.
        var ranked: [(vault: String, result: SearchResult)] = []
        var substring: [(vault: String, note: Note)] = []
        for entry in entries {
            let vault = Vault(path: store.resolvedPath(for: entry))
            if let results = try? ftsSearch(vault: vault) {
                ranked.append(contentsOf: results.map { (entry.name, $0) })
            } else if let notes = try? vault.searchNotes(query: query) {
                substring.append(contentsOf: notes.map { (entry.name, $0) })
            }
        }
        ranked.sort { $0.result.rank < $1.result.rank }
        ranked = Array(ranked.prefix(limit))
        substring = Array(substring.prefix(max(0, limit - ranked.count)))

        if outputOption.json {
            var jsonArray: [[String: Any]] = ranked.map { hit in
                [
                    "vault": hit.vault,
                    "path": hit.result.path,
                    "title": hit.result.title,
                    "tags": hit.result.tags,
                    "snippet": hit.result.snippet,
                    "rank": hit.result.rank,
                ]
            }
            jsonArray.append(contentsOf: substring.map { hit in
                [
                    "vault": hit.vault,
                    "path": hit.note.relativePath,
                    "title": hit.note.title,
                    "tags": hit.note.tags,
                    "snippet": "",
                ]
            })
            if let data = try? JSONSerialization.data(
                withJSONObject: jsonArray,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ), let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return
        }

        let totalCount = ranked.count + substring.count
        if totalCount == 0 {
            print("No results for: \(query)")
            return
        }

        print("Found \(totalCount) result(s) for \"\(query)\":\n")

        for (vaultName, result) in ranked {
            let tags = result.tags.isEmpty ? "" : " [\(result.tags.joined(separator: ", "))]"
            print("  [\(vaultName)] \(result.path)")
            print("    \(result.title)\(tags)")
            if !result.snippet.isEmpty {
                print("    … \(result.snippet)")
            }
            print()
        }
        for (vaultName, note) in substring {
            let tags = note.tags.isEmpty ? "" : " [\(note.tags.joined(separator: ", "))]"
            print("  [\(vaultName)] \(note.relativePath)")
            print("    \(note.title)\(tags)")
            let queryLower = query.lowercased()
            for line in note.body.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && trimmed.lowercased().contains(queryLower) {
                    print("    … \(trimmed.prefix(120))")
                    break
                }
            }
            print()
        }
    }

    // MARK: - Single-vault helpers

    /// Keyword search against an index that is brought up to date first, so notes
    /// written or edited since the last `mn index` (by this CLI, the app, or a sync) are found.
    private func ftsSearch(vault: Vault) throws -> [SearchResult] {
        if !SearchIndex.indexExists(vaultPath: vault.path) {
            printError("Building search index...")
        }
        let index = try SearchIndex(vaultPath: vault.path)
        try index.refresh(from: vault)
        return try index.search(query: query)
    }

    private func outputResults(_ results: [SearchResult], vaultName: String?, fts: Bool) {
        if outputOption.json {
            let jsonArray = results.map { r -> [String: Any] in
                var d: [String: Any] = [
                    "path": r.path,
                    "title": r.title,
                    "tags": r.tags,
                    "snippet": r.snippet,
                    "rank": r.rank,
                ]
                if let v = vaultName { d["vault"] = v }
                return d
            }
            if let data = try? JSONSerialization.data(withJSONObject: jsonArray, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return
        }

        if results.isEmpty {
            print("No results for: \(query)")
            return
        }

        print("Found \(results.count) result(s) for \"\(query)\":\n")
        for result in results {
            let tags = result.tags.isEmpty ? "" : " [\(result.tags.joined(separator: ", "))]"
            let prefix = vaultName.map { "[\($0)] " } ?? ""
            print("  \(prefix)\(result.path)")
            print("    \(result.title)\(tags)")
            if !result.snippet.isEmpty {
                print("    … \(result.snippet)")
            }
            print()
        }
    }

    private func outputSubstringResults(_ results: [Note], vaultName: String?) {
        if outputOption.json {
            try? printJSON(results.map { NoteOutput($0, includeBody: false) })
            return
        }

        if results.isEmpty {
            print("No results for: \(query)")
            return
        }

        print("Found \(results.count) result(s) for \"\(query)\" (substring):\n")
        for note in results {
            let tags = note.tags.isEmpty ? "" : " [\(note.tags.joined(separator: ", "))]"
            let prefix = vaultName.map { "[\($0)] " } ?? ""
            print("  \(prefix)\(note.relativePath)")
            print("    \(note.title)\(tags)")

            let lines = note.body.components(separatedBy: "\n")
            let queryLower = query.lowercased()
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && trimmed.lowercased().contains(queryLower) {
                    let snippet = trimmed.prefix(120)
                    print("    … \(snippet)")
                    break
                }
            }
            print()
        }
    }
}
