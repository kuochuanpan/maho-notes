import ArgumentParser
import Foundation
import MahoNotesKit

struct IndexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Build or rebuild the full-text search index"
    )

    @OptionGroup var vaultOption: VaultOption
    @OptionGroup var outputOption: OutputOption

    @Flag(name: .long, help: "Full rebuild (drop and recreate)")
    var full = false

    @Flag(name: .long, help: "Index all registered vaults")
    var all = false

    @Option(name: .long, help: "Embedding model for vector index (minilm, e5-small, e5-large)")
    var model: String?

    func run() async throws {
        if all {
            try await runAllVaults()
            return
        }
        try vaultOption.validateVaultExists()
        let vault = vaultOption.makeVault()
        let notes = try vault.allNotes()

        if !outputOption.json {
            if full {
                print("Rebuilding search index from scratch...")
            } else {
                print("Updating search index...")
            }
        }

        let index = try SearchIndex(vaultPath: vault.path)
        let stats = try index.buildIndex(notes: notes, fullRebuild: full)

        if outputOption.json {
            try printJSON(stats)
        } else {
            print("Indexed \(stats.total) notes (\(stats.added) new, \(stats.updated) updated, \(stats.deleted) deleted)")
        }

        // Resolve model: --model flag > vault device config > global config
        let resolvedModel = model ?? Config.resolveEmbedModel(vaultPath: vault.path)
        if let modelName = resolvedModel {
            if #available(macOS 15.0, *) {
                try await buildVectorIndex(vault: vault, notes: notes, modelName: modelName)
                // Persist model choice to vault device config
                let config = Config(vaultPath: vault.path)
                try config.setValue(key: "embed.model", value: modelName)
            } else {
                throw ValidationError("Vector indexing requires macOS 15+")
            }
        }
    }

    @available(macOS 15.0, *)
    private func buildVectorIndex(vault: Vault, notes: [Note], modelName: String) async throws {
        guard let embeddingModel = EmbeddingModel(rawValue: modelName) else {
            throw ValidationError("Unknown model '\(modelName)'. Supported: \(EmbeddingModel.allCases.map(\.rawValue).joined(separator: ", "))")
        }

        if !outputOption.json {
            print("Building vector index with model '\(modelName)'...")
        }

        let provider = SwiftEmbeddingsProvider(model: embeddingModel)
        let vecIndex: VectorIndex
        do {
            vecIndex = try VectorIndex(vaultPath: vault.path, dimensions: embeddingModel.dimensions)
        } catch let error as VectorIndexError {
            if case .dimensionMismatch = error, full {
                // Dimension changed but --full was requested, so reset and recreate
                let idx = try VectorIndex(vaultPath: vault.path, dimensions: embeddingModel.dimensions, skipDimensionCheck: true)
                try idx.resetSchema()
                let stats = try await idx.buildIndex(
                    notes: notes,
                    asyncEmbedder: { texts in try await provider.embedBatch(texts) },
                    model: modelName,
                    fullRebuild: true
                )
                if !outputOption.json {
                    print("Vector index: \(stats.totalChunks) chunks (\(stats.added) new, \(stats.updated) updated, \(stats.deleted) deleted)")
                }
                return
            }
            throw error
        }

        let vecStats = try await vecIndex.buildIndex(
            notes: notes,
            asyncEmbedder: { texts in
                try await provider.embedBatch(texts)
            },
            model: modelName,
            fullRebuild: full
        )

        if !outputOption.json {
            print("Vector index: \(vecStats.totalChunks) chunks (\(vecStats.added) new, \(vecStats.updated) updated, \(vecStats.deleted) deleted)")
        }
    }

    // MARK: - Cross-vault

    private func runAllVaults() async throws {
        guard let entries = vaultOption.allVaultEntries(), !entries.isEmpty else {
            print("No vaults registered. Use `mn vault add` to add one.")
            return
        }

        struct VaultStats: Encodable {
            let vault: String
            let total: Int
            let added: Int
            let updated: Int
            let deleted: Int
        }
        var allStats: [VaultStats] = []
        let store = VaultStore()

        for entry in entries {
            let path = store.resolvedPath(for: entry)
            let vault = Vault(path: path)

            if !outputOption.json {
                let action = full ? "Rebuilding" : "Updating"
                print("\(action) index for vault '\(entry.name)'...")
            }

            do {
                let notes = try vault.allNotes()
                let index = try SearchIndex(vaultPath: vault.path)
                let stats = try index.buildIndex(notes: notes, fullRebuild: full)

                if outputOption.json {
                    allStats.append(VaultStats(
                        vault: entry.name,
                        total: stats.total,
                        added: stats.added,
                        updated: stats.updated,
                        deleted: stats.deleted
                    ))
                } else {
                    print("  [\(entry.name)] \(stats.total) notes (\(stats.added) new, \(stats.updated) updated, \(stats.deleted) deleted)")
                }
            } catch {
                if outputOption.json {
                    allStats.append(VaultStats(vault: entry.name, total: 0, added: 0, updated: 0, deleted: 0))
                } else {
                    print("  [\(entry.name)] Failed: \(error.localizedDescription)")
                }
            }
        }

        if outputOption.json {
            try printJSON(allStats)
        }
    }
}
