import Foundation

/// Structural hints about a model's architecture, used by the memory
/// estimator. All fields optional: what isn't known widens estimate ranges
/// instead of being silently zeroed.
public struct ArchitectureHints: Codable, Sendable, Hashable {
    public var numLayers: Int?
    public var hiddenSize: Int?
    public var numAttentionHeads: Int?
    /// Key/value heads for grouped-query attention; defaults to
    /// `numAttentionHeads` when nil.
    public var numKVHeads: Int?
    /// Per-head dimension; defaults to hiddenSize / numAttentionHeads.
    public var headDim: Int?
    public var vocabSize: Int?
    public var intermediateSize: Int?
    /// Sliding attention window in tokens (Mistral/Gemma style); caps the
    /// effective KV cache growth when smaller than the context.
    public var slidingWindow: Int?
    /// Approximate parameter count of a vision encoder tower, for VLMs.
    public var visionEncoderParams: Int64?
    /// Bytes per KV cache element (2 = fp16, the common default).
    public var kvCacheDTypeBytes: Int
    /// Native (fixed) output resolution for Core ML diffusion models, e.g.
    /// 512 for SD 1.x/2.x, 1024 for SDXL. Core ML shapes are compiled in;
    /// the runtime cannot resize.
    public var diffusionResolution: Int?

    public init(
        numLayers: Int? = nil,
        hiddenSize: Int? = nil,
        numAttentionHeads: Int? = nil,
        numKVHeads: Int? = nil,
        headDim: Int? = nil,
        vocabSize: Int? = nil,
        intermediateSize: Int? = nil,
        slidingWindow: Int? = nil,
        visionEncoderParams: Int64? = nil,
        kvCacheDTypeBytes: Int = 2,
        diffusionResolution: Int? = nil
    ) {
        self.numLayers = numLayers
        self.hiddenSize = hiddenSize
        self.numAttentionHeads = numAttentionHeads
        self.numKVHeads = numKVHeads
        self.headDim = headDim
        self.vocabSize = vocabSize
        self.intermediateSize = intermediateSize
        self.slidingWindow = slidingWindow
        self.visionEncoderParams = visionEncoderParams
        self.kvCacheDTypeBytes = kvCacheDTypeBytes
        self.diffusionResolution = diffusionResolution
    }

    /// Effective KV heads: numKVHeads ?? numAttentionHeads.
    public var effectiveKVHeads: Int? { numKVHeads ?? numAttentionHeads }

    /// Effective per-head dimension.
    public var effectiveHeadDim: Int? {
        if let headDim { return headDim }
        guard let hiddenSize, let numAttentionHeads, numAttentionHeads > 0 else { return nil }
        return hiddenSize / numAttentionHeads
    }

    /// Maps a GGUF metadata dictionary ("<arch>.block_count",
    /// "<arch>.attention.head_count_kv", "<arch>.embedding_length", …) into
    /// hints. Values are untyped because the GGUF parser lives in another
    /// module; numbers and strings convertible to Int are accepted.
    public init(ggufMetadata metadata: [String: Any]) {
        // GGUF keys carry the architecture as a prefix; find it from a
        // known key rather than guessing the arch name.
        let prefix = metadata.keys.first { $0.hasSuffix(".block_count") }
            .map { String($0.dropLast(".block_count".count)) } ?? ""
        func aint(_ suffix: String) -> Int? {
            prefix.isEmpty ? nil : Self.ggufInt(metadata, key: "\(prefix).\(suffix)")
        }
        let vocabCount = (metadata["tokenizer.ggml.tokens"] as? [Any])?.count

        self.init(
            numLayers: aint("block_count"),
            hiddenSize: aint("embedding_length"),
            numAttentionHeads: aint("attention.head_count"),
            numKVHeads: aint("attention.head_count_kv"),
            headDim: nil,
            vocabSize: vocabCount,
            intermediateSize: aint("feed_forward_length"),
            slidingWindow: aint("attention.sliding_window"),
            visionEncoderParams: nil,
            kvCacheDTypeBytes: 2
        )
    }

    private static func ggufInt(_ metadata: [String: Any], key: String) -> Int? {
        switch metadata[key] {
        case let n as Int: return n
        case let n as Int32: return Int(n)
        case let n as Int64: return Int(n)
        case let n as UInt32: return Int(n)
        case let n as UInt64: return Int(n)
        case let n as Double: return Int(n)
        case let n as Float: return Int(n)
        case let s as String: return Int(s)
        default: return nil
        }
    }
}
