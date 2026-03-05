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
}
