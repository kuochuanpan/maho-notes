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
    /// Tracks total embed() calls for periodic memory flush.
    private var embedCallCount = 0
    /// Flush model every N embed() calls to release CoreML memory pools.
    /// Lower = more frequent reloads (~0.5s each) but tighter memory envelope.
    private var flushInterval = 10

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
        // Periodically unload model to force CoreML to release internal memory pools.
        // MLTensor buffers grow during inference and never shrink — this is the only
        // way to reclaim memory. Re-load is fast (~0.5s from disk cache).
        embedCallCount += 1
        if embedCallCount > flushInterval {
            unloadModel()
            embedCallCount = 0
            try await Task.sleep(for: .milliseconds(50))
        }

        try await ensureLoaded()

        // CoreML inference produces ObjC autorelease buffers (attention matmul,
        // layer norms, etc.) that accumulate in Swift async contexts because
        // there's no implicit autorelease pool drain between await points.
        // Without this, memory grows ~50-100 MB per embed() call and never
        // shrinks until the entire Task completes — causing ~800 MB residual
        // after building a vault and OOM crashes with multiple vaults.
        //
        // Strategy: run the synchronous encode() inside autoreleasepool to
        // drain ObjC intermediates, then await the MLTensor → Float conversion
        // in a second autoreleasepool.

        // Phase 1: synchronous model inference (produces MLTensor graph + ObjC buffers)
        let tensor: MLTensor = try autoreleasepool {
            try withMLTensorComputePolicy(.cpuAndGPU) {
                switch model {
                case .minilm:
                    return try bertBundle!.encode(text, maxLength: 512)
                case .e5small, .e5large:
                    return try xlmBundle!.encode(text, maxLength: 512)
                }
            }
        }

        // Phase 2: async eager evaluation (shapedArray triggers actual compute).
        // cast() is synchronous (builds lazy graph), shapedArray is async (runs compute).
        let shaped = await tensor.cast(to: Float.self).shapedArray(of: Float.self)

        // Phase 3: copy scalars out and drain any remaining ObjC buffers from evaluation.
        let scalars: [Float] = autoreleasepool {
            Array(shaped.scalars)
        }
        return scalars
    }

    public func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        var results: [[Float]] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            let vec = try await embed(text)
            results.append(vec)
        }
        return results
    }
}
