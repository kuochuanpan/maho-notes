import Testing
import Foundation
@testable import MahoNotesKit

/// Mock embedding provider for testing.
struct MockEmbeddingProvider: EmbeddingProvider {
    let dimensions: Int = 384
    let modelIdentifier: String = "mock"

    func embed(_ text: String) async throws -> [Float] {
        let seed = Float(abs(text.hashValue % 1000))
        return (0..<dimensions).map { i in sin(seed * Float(i + 1) * 0.01) }
    }

    func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        var results: [[Float]] = []
        for text in texts {
            try await results.append(embed(text))
        }
        return results
    }
}

@Suite("EmbeddingProvider")
struct EmbeddingProviderTests {

    @Test func mockProviderReturnsCorrectDimensions() async throws {
        let provider = MockEmbeddingProvider()
        let result = try await provider.embed("hello world")
        #expect(result.count == 384)
    }

    @Test func mockProviderBatchReturnsCorrectCount() async throws {
        let provider = MockEmbeddingProvider()
        let results = try await provider.embedBatch(["hello", "world", "test"])
        #expect(results.count == 3)
        for r in results {
            #expect(r.count == 384)
        }
    }

    @Test func embeddingModelAliases() {
        #expect(EmbeddingModel.minilm.huggingFaceId == "sentence-transformers/all-MiniLM-L6-v2")
        #expect(EmbeddingModel.e5small.huggingFaceId == "intfloat/multilingual-e5-small")
        #expect(EmbeddingModel.minilm.dimensions == 384)
        #expect(EmbeddingModel(rawValue: "minilm") == .minilm)
        #expect(EmbeddingModel(rawValue: "e5-small") == .e5small)
    }

    @Test func bgeM3ModelProperties() {
        let model = EmbeddingModel.bgeM3
        #expect(model.rawValue == "bge-m3")
        #expect(model.huggingFaceId == "BAAI/bge-m3")
        #expect(model.dimensions == 1024)
        #expect(EmbeddingModel(rawValue: "bge-m3") == .bgeM3)
    }

    @Test func dimensionsPerCase() {
        #expect(EmbeddingModel.minilm.dimensions == 384)
        #expect(EmbeddingModel.e5small.dimensions == 384)
        #expect(EmbeddingModel.bgeM3.dimensions == 1024)
    }

    @Test func displayNameForAllModels() {
        #expect(EmbeddingModel.minilm.displayName == "MiniLM-L6-v2")
        #expect(EmbeddingModel.e5small.displayName == "Multilingual E5 Small")
        #expect(EmbeddingModel.bgeM3.displayName == "BGE-M3")
    }

    @Test func approximateSizeForAllModels() {
        #expect(EmbeddingModel.minilm.approximateSize == "~80 MB")
        #expect(EmbeddingModel.e5small.approximateSize == "~120 MB")
        #expect(EmbeddingModel.bgeM3.approximateSize == "~2.2 GB")
    }

    @Test func allCasesIncludesBgeM3() {
        #expect(EmbeddingModel.allCases.count == 3)
        #expect(EmbeddingModel.allCases.contains(.bgeM3))
    }
}
