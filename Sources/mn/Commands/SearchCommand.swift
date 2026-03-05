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

    @Option(name: .long, help: "Maximum number of results (default 10)")
    var limit: Int = 10

    func run() async throws {
        if semantic || hybrid {
            if #available(macOS 15.0, *) {
                // Cross-vault semantic/hybrid: iterate all vaults
                let searchAll = all || vaultOption.vault == nil
                if searchAll, let entries = vaultOption.allVaultEntries(), !entries.isEmpty {
                    for entry in entries {
                        let vault = Vault(path: MahoNotesKit.resolvedPath(for: entry))
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
            outputResults(results, vaultName: nil, fts: true)
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
            outputSubstringResults(results, vaultName: nil)
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
                let queryVector = try await provider.embed(query)
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
        let queryVector = try await provider.embed(query)
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
            if let data = try? JSONSerialization.data(withJSONObject: jsonArray, options: [.prettyPrinted, .sortedKeys]),
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
            if let data = try? JSONSerialization.data(withJSONObject: jsonArray, options: [.prettyPrinted, .sortedKeys]),
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
        if outputOption.json {
            var jsonArray: [[String: Any]] = []
            for entry in entries {
                let vault = Vault(path: MahoNotesKit.resolvedPath(for: entry))
                if let results = try? ftsSearch(vault: vault) {
                    for r in results {
                        jsonArray.append([
                            "vault": entry.name,
                            "path": r.path,
                            "title": r.title,
                            "tags": r.tags,
                            "snippet": r.snippet,
                            "rank": r.rank,
                        ])
                    }
                } else if let notes = try? vault.searchNotes(query: query) {
                    for n in notes {
                        jsonArray.append([
                            "vault": entry.name,
                            "path": n.relativePath,
                            "title": n.title,
                            "tags": n.tags,
                            "snippet": "",
                        ])
                    }
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: jsonArray, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return
        }

        var totalCount = 0
        var output: [(vaultName: String, results: [SearchResult])] = []
        var substringOutput: [(vaultName: String, results: [Note])] = []
        var usedFts = true

        for entry in entries {
            let path = MahoNotesKit.resolvedPath(for: entry)
            let vault = Vault(path: path)
            if let results = try? ftsSearch(vault: vault) {
                if !results.isEmpty {
                    output.append((entry.name, results))
                    totalCount += results.count
                }
            } else {
                usedFts = false
                if let results = try? vault.searchNotes(query: query), !results.isEmpty {
                    substringOutput.append((entry.name, results))
                    totalCount += results.count
                }
            }
        }

        if totalCount == 0 {
            print("No results for: \(query)")
            return
        }

        let label = usedFts ? "" : " (substring)"
        print("Found \(totalCount) result(s) for \"\(query)\"\(label):\n")

        for (vaultName, results) in output {
            for result in results {
                let tags = result.tags.isEmpty ? "" : " [\(result.tags.joined(separator: ", "))]"
                print("  [\(vaultName)] \(result.path)")
                print("    \(result.title)\(tags)")
                if !result.snippet.isEmpty {
                    print("    … \(result.snippet)")
                }
                print()
            }
        }
        for (vaultName, notes) in substringOutput {
            for note in notes {
                let tags = note.tags.isEmpty ? "" : " [\(note.tags.joined(separator: ", "))]"
                print("  [\(vaultName)] \(note.relativePath)")
                print("    \(note.title)\(tags)")
                let lines = note.body.components(separatedBy: "\n")
                let queryLower = query.lowercased()
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty && trimmed.lowercased().contains(queryLower) {
                        print("    … \(trimmed.prefix(120))")
                        break
                    }
                }
                print()
            }
        }
    }

    // MARK: - Single-vault helpers

    private func ftsSearch(vault: Vault) throws -> [SearchResult] {
        if !SearchIndex.indexExists(vaultPath: vault.path) {
            FileHandle.standardError.write(
                "Building search index...\n".data(using: .utf8)!
            )
            let index = try SearchIndex(vaultPath: vault.path)
            let notes = try vault.allNotes()
            try index.buildIndex(notes: notes)
            return try index.search(query: query)
        }
        let index = try SearchIndex(vaultPath: vault.path)
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
            if let data = try? JSONSerialization.data(withJSONObject: jsonArray, options: [.prettyPrinted, .sortedKeys]),
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
            try? printJSON(results)
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
