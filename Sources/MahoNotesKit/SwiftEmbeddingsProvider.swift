import CoreML
import Embeddings
import Foundation

/// Supported embedding model aliases.
public enum EmbeddingModel: String, Sendable, CaseIterable {
    case minilm
    case e5small = "e5-small"
    case e5large = "e5-large"

    public var huggingFaceId: String {
        switch self {
        case .minilm: return "sentence-transformers/all-MiniLM-L6-v2"
        case .e5small: return "intfloat/multilingual-e5-small"
        case .e5large: return "intfloat/multilingual-e5-large"
        }
    }

    public var dimensions: Int {
        switch self {
        case .minilm: return 384
        case .e5small: return 384
        case .e5large: return 1024
        }
    }

    public var displayName: String {
        switch self {
        case .minilm: return "MiniLM-L6-v2"
        case .e5small: return "Multilingual E5 Small"
        case .e5large: return "Multilingual E5 Large"
        }
    }

    public var approximateSize: String {
        switch self {
        case .minilm: return "~80 MB"
        case .e5small: return "~120 MB"
        case .e5large: return "~2.2 GB"
        }
    }

    /// Whether this model requires "query: " / "passage: " instruction prefixes.
    /// E5 models use asymmetric encoding and need these prefixes for proper cross-lingual matching.
    public var requiresPrefix: Bool {
        switch self {
        case .minilm: return false
        case .e5small, .e5large: return true
        }
    }

    /// Whether this model is suitable for iOS (memory-constrained devices).
    /// E5 Large uses ~2.2 GB base + inference buffers, exceeding iOS limits.
    public var availableOnIOS: Bool {
        switch self {
        case .minilm, .e5small: return true
        case .e5large: return false
        }
    }
}

/// Default directory for cached embedding models (device-local, not synced to iCloud).
public let defaultModelCacheDir: String = {
    let base = mahoConfigBase()
    return (base as NSString).appendingPathComponent("models")
}()

/// Clean corrupted HubApi metadata cache that can block model downloads.
///
/// `swift-transformers` HubApi stores `.metadata` files alongside downloaded model files.
/// If these become corrupted (e.g. interrupted download, crash), HubApi throws
/// `invalidMetadataError` and cannot self-recover when it lacks delete permission.
/// This function removes the entire metadata cache directory, forcing a clean re-download.
public func cleanModelMetadataCache() {
    let metadataDir = (defaultModelCacheDir as NSString).appendingPathComponent(".cache/huggingface/download")
    if FileManager.default.fileExists(atPath: metadataDir) {
        try? FileManager.default.removeItem(atPath: metadataDir)
        Log.search.info("Cleaned model metadata cache at \(metadataDir)")
    }
}

/// Wraps swift-embeddings for text embedding using Bert or XLMRoberta models.
@available(macOS 15.0, *)
public final class SwiftEmbeddingsProvider: EmbeddingProvider, @unchecked Sendable {
    private let model: EmbeddingModel
    private var bertBundle: Bert.ModelBundle?
    private var xlmBundle: XLMRoberta.ModelBundle?
    private var loaded = false

    public var dimensions: Int { model.dimensions }
    public var modelIdentifier: String { model.rawValue }
    public var requiresPrefix: Bool { model.requiresPrefix }

    public init(model: EmbeddingModel = .minilm) {
        self.model = model
    }

    /// Release model weights from memory. Call after batch operations to free RAM.
    /// The model will be re-loaded on the next `embed()` call.
    public func unloadModel() {
        bertBundle = nil
        xlmBundle = nil
        loaded = false
    }

    private func ensureLoaded() async throws {
        guard !loaded else { return }
        let cacheURL = URL(fileURLWithPath: defaultModelCacheDir)
        switch model {
        case .minilm:
            bertBundle = try await Bert.loadModelBundle(
                from: model.huggingFaceId,
                downloadBase: cacheURL
            )
        case .e5small:
            xlmBundle = try await XLMRoberta.loadModelBundle(
                from: model.huggingFaceId,
                downloadBase: cacheURL,
                loadConfig: .init()
            )
        case .e5large:
            xlmBundle = try await XLMRoberta.loadModelBundle(
                from: model.huggingFaceId,
                downloadBase: cacheURL,
                loadConfig: .init()
            )
        }
        loaded = true
    }

    public func embed(_ text: String) async throws -> [Float] {
        try await ensureLoaded()
        // Wrap in cpuAndGPU compute policy to avoid EXC_BAD_ACCESS in
        // BNNS.BroadcastMatrixMultiplyLayer during attention matmul.
        // See: https://github.com/jkrukowski/swift-embeddings/pull/18
        let tensor: MLTensor = try withMLTensorComputePolicy(.cpuAndGPU) {
            switch model {
            case .minilm:
                return try bertBundle!.encode(text, maxLength: 512)
            case .e5small, .e5large:
                return try xlmBundle!.encode(text, maxLength: 512)
            }
        }
        // Force eager evaluation and copy scalars into a plain Array<Float>.
        // The MLTensor graph can then be released by ARC.
        let shaped = await tensor.cast(to: Float.self).shapedArray(of: Float.self)
        return Array(shaped.scalars)
    }

    public func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        // Delegate to memory-managed version with default flush interval
        return try await embedBatchWithFlush(texts)
    }

    /// Embed multiple texts with periodic model unload to cap memory.
    ///
    /// MLTensor's internal memory pools grow during inference and don't shrink
    /// within a process. To prevent unbounded growth (3+ GB for E5 Small on iOS),
    /// we unload the model every `flushInterval` embeddings, forcing CoreML to
    /// release all intermediate buffers. The model is re-loaded on the next call.
    ///
    /// - Parameter flushInterval: Unload model every N embeddings (default 25).
    public func embedBatchWithFlush(_ texts: [String], flushInterval: Int = 25) async throws -> [[Float]] {
        var results: [[Float]] = []
        results.reserveCapacity(texts.count)
        for (i, text) in texts.enumerated() {
            let vec = try await embed(text)
            results.append(vec)

            // Periodically unload model to force CoreML to release memory.
            // Re-loading from disk cache is fast (~0.5s) and prevents OOM.
            if (i + 1) % flushInterval == 0 && i + 1 < texts.count {
                unloadModel()
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        return results
    }
}
