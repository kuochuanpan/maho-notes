import Foundation

/// Protocol for text embedding providers.
public protocol EmbeddingProvider: Sendable {
    var dimensions: Int { get }
    var modelIdentifier: String { get }
    /// Whether this model requires instruction prefixes (e.g. E5 "query: " / "passage: ").
    var requiresPrefix: Bool { get }
    func embed(_ text: String) async throws -> [Float]
    func embedBatch(_ texts: [String]) async throws -> [[Float]]
}

extension EmbeddingProvider {
    /// Default: no prefix required.
    public var requiresPrefix: Bool { false }

    /// Embed a search query. For models like E5 that need prefixes, prepends "query: ".
    public func embedQuery(_ text: String) async throws -> [Float] {
        if requiresPrefix {
            return try await embed("query: " + text)
        }
        return try await embed(text)
    }

    /// Embed document passages for indexing. For E5 models, prepends "passage: ".
    public func embedPassage(_ text: String) async throws -> [Float] {
        if requiresPrefix {
            return try await embed("passage: " + text)
        }
        return try await embed(text)
    }

    /// Batch embed document passages for indexing.
    public func embedPassageBatch(_ texts: [String]) async throws -> [[Float]] {
        if requiresPrefix {
            return try await embedBatch(texts.map { "passage: " + $0 })
        }
        return try await embedBatch(texts)
    }
}
