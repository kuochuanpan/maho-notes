import Foundation

/// Protocol for text embedding providers.
public protocol EmbeddingProvider: Sendable {
    var dimensions: Int { get }
    var modelIdentifier: String { get }
    func embed(_ text: String) async throws -> [Float]
    func embedBatch(_ texts: [String]) async throws -> [[Float]]
}
