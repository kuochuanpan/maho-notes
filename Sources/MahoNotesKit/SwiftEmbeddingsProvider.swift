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
    /// With cpuOnly compute policy (avoids Metal memory pool leaks):
    /// - MiniLM: ~170 MB peak, ~100 MB after unload — fits all iPhones
    /// - E5 Small: ~743 MB peak, ~247 MB after unload — tight on 4 GB devices, OK on 6 GB+
    /// - E5 Large: ~2.2 GB — exceeds iOS limits
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

        // Use CPU-only compute policy to avoid Metal GPU memory pool leaks.
        //
        // Root cause: Apple's Metal allocator maintains a process-level buffer pool
        // that never shrinks. Each MLTensor GPU inference adds ~7 MB to this pool,
        // accumulating to ~800 MB+ over 100+ embed() calls and never releasing —
        // even after unloadModel() or autoreleasepool drains.
        //
        // With cpuOnly on Apple Silicon (tested on M4):
        //   MiniLM:   ~170 MB peak, stable across 100+ calls, drops to ~100 MB on unload
        //   E5 Small: ~743 MB peak, stable, drops to ~247 MB on unload
        //
        // With cpuAndGPU (broken):
        //   MiniLM:   grows to 800+ MB, never releases
        //   E5 Small: grows to 1.4 GB+, causes EXC_RESOURCE on iOS
        //
        // CPU inference is fast enough: MiniLM ~15ms/chunk, E5 Small ~40ms/chunk.
        let tensor: MLTensor = try autoreleasepool {
            try withMLTensorComputePolicy(.cpuOnly) {
                switch model {
                case .minilm:
                    return try bertBundle!.encode(text, maxLength: 512)
                case .e5small, .e5large:
                    return try xlmBundle!.encode(text, maxLength: 512)
                }
            }
        }

        // Eager evaluation: shapedArray triggers actual compute on CPU.
        let shaped = await tensor.cast(to: Float.self).shapedArray(of: Float.self)

        return autoreleasepool { Array(shaped.scalars) }
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
