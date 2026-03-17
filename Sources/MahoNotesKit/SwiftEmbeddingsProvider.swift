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

    /// Embed multiple texts with aggressive memory management.
    ///
    /// Each embedding is computed in an isolated context to prevent MLTensor
    /// computation graphs from accumulating across the batch. This is critical
    /// on iOS where the memory limit is ~1.5 GB and E5 models use ~500 MB.
    public func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        var results: [[Float]] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            // Embed in isolation: the local `vec` Array<Float> is the only
            // thing that survives; all MLTensor intermediates become eligible
            // for ARC release.
            let vec = try await embed(text)
            results.append(vec)
        }
        return results
    }
}
