import ArgumentParser
import Foundation
import MahoNotesKit

struct MemProfileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "memprofile",
        abstract: "Profile memory usage during vector index build (debug tool)"
    )

    @OptionGroup var vaultOption: VaultOption

    @Option(name: .long, help: "Embedding model (minilm, e5-small)")
    var model: String = "e5-small"

    @Flag(name: .long, help: "Test cross-vault memory by building all vaults sequentially")
    var all = false

    func run() async throws {
        guard #available(macOS 15.0, *) else {
            throw ValidationError("Requires macOS 15+")
        }

        if all {
            try await profileAllVaults()
        } else {
            try vaultOption.validateVaultExists()
            let vault = vaultOption.makeVault()
            try await profileSingleVault(vault: vault)
        }
    }

    @available(macOS 15.0, *)
    private func profileSingleVault(vault: Vault) async throws {
        let notes = try vault.allNotes()
        print("=== Memory Profile: \(vault.path) ===")
        print("Notes: \(notes.count)")
        print("Baseline: \(memMB()) MB")

        guard let embModel = EmbeddingModel(rawValue: model) else {
            throw ValidationError("Unknown model: \(model)")
        }

        // Chunk all notes first
        var allChunks: [(note: Note, chunks: [(id: Int, text: String)])] = []
        for note in notes {
            let chunks = Chunker.chunkNote(title: note.title, body: note.body)
                .map { (id: $0.id, text: $0.text) }
            if !chunks.isEmpty {
                allChunks.append((note: note, chunks: chunks))
            }
        }
        let totalChunks = allChunks.reduce(0) { $0 + $1.chunks.count }
        print("Total chunks to embed: \(totalChunks)")

        // === Strategy: CPU-only to avoid Metal memory pool leaks ===
        print("\n--- Strategy: cpuOnly compute policy ---")
        let allTexts = allChunks.flatMap { $0.chunks.map { $0.text } }
        var allVectors: [[Float]] = []
        allVectors.reserveCapacity(totalChunks)

        let provider = SwiftEmbeddingsProvider(model: embModel)
        for (i, text) in allTexts.enumerated() {
            let vec = try await provider.embedPassage(text)
            allVectors.append(vec)
            if (i + 1) % 20 == 0 || i + 1 == allTexts.count {
                print("  After \(i+1)/\(totalChunks) embeds: \(memMB()) MB")
            }
        }

        print("\nAfter all embeds: \(memMB()) MB")
        provider.unloadModel()
        print("After unloadModel(): \(memMB()) MB")
        allVectors = []
        try await Task.sleep(for: .seconds(2))
        print("After cleanup + 2s wait: \(memMB()) MB")

        print("\n=== Summary ===")
        print("Model: \(embModel.displayName)")
        print("Notes: \(notes.count), Chunks: \(totalChunks)")
        print("Final memory: \(memMB()) MB")
    }

    @available(macOS 15.0, *)
    private func profileAllVaults() async throws {
        guard let entries = vaultOption.allVaultEntries(), !entries.isEmpty else {
            print("No vaults registered.")
            return
        }
        let store = VaultStore.shared

        print("=== Cross-Vault Memory Profile ===")
        print("Baseline: \(memMB()) MB")
        print("Vaults: \(entries.count)")
        print()

        guard let embModel = EmbeddingModel(rawValue: model) else {
            throw ValidationError("Unknown model: \(model)")
        }

        for (i, entry) in entries.enumerated() {
            let path = store.resolvedPath(for: entry)
            let vault = Vault(path: path)
            let notes = try vault.allNotes()
            let totalChunks = notes.reduce(0) { $0 + Chunker.chunkNote(title: $1.title, body: $1.body).count }

            print("--- Vault \(i+1)/\(entries.count): \(entry.name) (\(notes.count) notes, \(totalChunks) chunks) ---")
            print("  Before: \(memMB()) MB")

            // Build vector index using the same code path as the app
            let provider = SwiftEmbeddingsProvider(model: embModel)
            let vecIndex = try VectorIndex(vaultPath: vault.path, dimensions: embModel.dimensions, skipDimensionCheck: true)
            try vecIndex.resetSchema()

            let stats = try await vecIndex.buildIndex(
                notes: notes,
                asyncEmbedder: { texts in try await provider.embedPassageBatch(texts) },
                model: model,
                fullRebuild: true
            )

            print("  After build: \(memMB()) MB (chunks: \(stats.totalChunks))")

            provider.unloadModel()
            print("  After unload: \(memMB()) MB")

            // Wait for cleanup
            try await Task.sleep(for: .seconds(1))
            print("  After 1s wait: \(memMB()) MB")
            print()
        }

        print("=== Final: \(memMB()) MB ===")
    }

    private func memMB() -> String {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            return String(format: "%.1f", Double(info.resident_size) / 1_048_576.0)
        }
        return "?"
    }
}
