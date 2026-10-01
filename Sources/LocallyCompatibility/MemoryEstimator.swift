import Foundation
import LocallyCore
import LocallyDevice

/// Estimated memory need for running one model, as a low/high range with a
/// component breakdown. Ranges widen when inputs are unknown; nothing here
/// is silently zeroed.
public struct MemoryEstimate: Codable, Sendable, Hashable {
    public enum Confidence: String, Codable, Sendable, Hashable {
        /// Real weight-file bytes plus known architecture.
        case high
        /// Parameter count and quantization known, structure partially known.
        case medium
        /// Key inputs missing; range deliberately wide.
        case low
    }

    public struct Component: Codable, Sendable, Hashable {
        public var name: String
        public var low: Int64
        public var high: Int64

        public init(name: String, low: Int64, high: Int64) {
            self.name = name
            self.low = low
            self.high = high
        }
    }

    public var low: Int64
    public var high: Int64
    public var components: [Component]
    public var confidence: Confidence
    /// Context length these numbers assume.
    public var contextLength: Int

    public init(low: Int64, high: Int64, components: [Component],
                confidence: Confidence, contextLength: Int) {
        self.low = low
        self.high = high
        self.components = components
        self.confidence = confidence
        self.contextLength = contextLength
    }
}

/// Estimates the memory a model needs at a given context length.
///
/// Model (documented in DECISIONS.md):
///   total = weights + KV cache(context) + activations + runtime overhead
///           + modality extras (vision encoder, diffusion buffers) + margin
/// Weights prefer the real download size over params × bits/8. The KV cache
/// is 2 × layers × kvHeads × headDim × context × dtypeBytes, capped by a
/// sliding attention window when one exists.
public struct MemoryEstimator: Sendable {
    /// Fraction of headroom added on top of the raw sum (safety margin).
    public var safetyMarginLow: Double
    public var safetyMarginHigh: Double

    public init(safetyMarginLow: Double = 0.10, safetyMarginHigh: Double = 0.15) {
        self.safetyMarginLow = safetyMarginLow
        self.safetyMarginHigh = safetyMarginHigh
    }

    /// Runtime fixed overhead per runtime kind, in bytes. Documented
    /// approximations: MLX keeps a Metal command-queue + buffer cache,
    /// llama.cpp keeps a compute buffer and scratch, CoreML keeps ANE/GPU
    /// intermediates. Diffusion/audio/video runtimes are heavier.
    public static func runtimeOverhead(for kind: RuntimeKind) -> (low: Int64, high: Int64) {
        switch kind {
        case .mlx: return (200_000_000, 400_000_000)
        case .gguf: return (150_000_000, 300_000_000)
        case .coreml: return (250_000_000, 500_000_000)
        case .diffusion: return (400_000_000, 800_000_000)
        case .audio: return (150_000_000, 300_000_000)
        case .vision: return (200_000_000, 400_000_000)
        case .video: return (500_000_000, 1_000_000_000)
        case .decision: return (10_000_000, 30_000_000)
        }
    }

    /// Quantization per-block metadata overhead: scales/zeros add roughly
    /// 3–8% at 4-bit group-64/128; wider when the scheme is unknown.
    public static func quantOverheadFactor(_ quantization: Quantization?) -> (low: Double, high: Double) {
        guard let quantization else { return (1.05, 1.20) }
        switch quantization.bits {
        case 2...4: return (1.04, 1.10)
        case 5...8: return (1.02, 1.05)
        default: return (1.0, 1.02)
        }
    }

    public struct Input: Sendable {
        public var descriptor: ModelDescriptor
        public var contextLength: Int
        public var runtime: RuntimeKind?
        /// Diffusion/video working resolution (pixels per side) when known.
        public var imageResolution: Int
        /// Video frame count for video understanding/generation.
        public var videoFrames: Int

        public init(descriptor: ModelDescriptor, contextLength: Int,
                    runtime: RuntimeKind? = nil, imageResolution: Int = 1024,
                    videoFrames: Int = 8) {
            self.descriptor = descriptor
            self.contextLength = contextLength
            self.runtime = runtime
            self.imageResolution = imageResolution
            self.videoFrames = videoFrames
        }
    }

    public func estimate(_ input: Input) -> MemoryEstimate {
        let d = input.descriptor
        let hints = d.architectureHints
        var components: [MemoryEstimate.Component] = []
        var unknowns = 0

        // MARK: Weights — prefer real file bytes, then params × bits/8.
        let weights: MemoryEstimate.Component
        if let real = d.totalDownloadSize, real > 0 {
            // Download size ≈ runtime weight footprint (weights + tokenizer).
            weights = .init(name: "Weights", low: real, high: real)
        } else if let params = d.parameterCount {
            let bytesPerParam = d.quantization?.bytesPerParameter ?? 2.0
            let overhead = Self.quantOverheadFactor(d.quantization)
            let base = Double(params) * bytesPerParam
            if d.quantization == nil { unknowns += 1 }
            weights = .init(name: "Weights",
                            low: Int64(base * overhead.low),
                            high: Int64(base * overhead.high))
        } else {
            unknowns += 2
            weights = .init(name: "Weights", low: 0, high: 0)
        }
        components.append(weights)

        // MARK: KV cache — 2 (K+V) × layers × kvHeads × headDim × context × bytes.
        if let layers = hints?.numLayers,
           let kvHeads = hints?.effectiveKVHeads,
           let headDim = hints?.effectiveHeadDim {
            let effectiveContext = min(input.contextLength, hints?.slidingWindow ?? input.contextLength)
            let bytes = Int64(2 * layers * kvHeads * headDim) * Int64(effectiveContext)
                * Int64(hints?.kvCacheDTypeBytes ?? 2)
            components.append(.init(name: "KV Cache", low: bytes, high: bytes))
        } else if d.modality == .text || d.modality == .visionLanguage {
            // Transformer shape unknown: fall back to params-proportional KV.
            unknowns += 1
            if let params = d.parameterCount, params > 0 {
                // Empirical: fp16 KV at 8K context ≈ 1–4% of param bytes for
                // typical GQA models; scale linearly with context.
                let base = Double(params) * 2.0 // fp16 param bytes
                let perToken = base * 0.02 / 8192.0
                let kv = Int64(perToken * Double(input.contextLength))
                components.append(.init(name: "KV Cache", low: kv / 2, high: kv * 2))
            }
        }

        // MARK: Activations / scratch — batch-1 decode working set.
        if let hidden = hints?.hiddenSize {
            // A few hidden-sized fp32 buffers per in-flight token chunk
            // (logits over vocab dominate for large vocabularies).
            let vocab = hints?.vocabSize ?? 32000
            let logits = Int64(vocab) * 4
            let scratch = Int64(hidden) * 4 * 64 // ~64 hidden-sized buffers
            let total = logits + scratch
            components.append(.init(name: "Activations", low: total, high: total * 2))
        } else if d.modality == .text || d.modality == .visionLanguage {
            unknowns += 1
            components.append(.init(name: "Activations", low: 50_000_000, high: 400_000_000))
        }

        // MARK: Runtime overhead.
        let runtime = input.runtime ?? d.supportedRuntimes.first
        if let runtime {
            let o = Self.runtimeOverhead(for: runtime)
            components.append(.init(name: "Runtime Overhead", low: o.low, high: o.high))
        } else {
            unknowns += 1
        }

        // MARK: Modality extras.
        switch d.modality {
        case .visionLanguage:
            if let vp = hints?.visionEncoderParams {
                let bytes = Int64(Double(vp) * 2.0) // fp16 weights
                // Plus decoded image buffer + patch embeddings (~1024px).
                let image = Int64(input.imageResolution * input.imageResolution * 3 * 2)
                components.append(.init(name: "Vision Encoder",
                                        low: bytes + image, high: bytes * 11 / 10 + image * 2))
            } else {
                unknowns += 1
                components.append(.init(name: "Vision Encoder",
                                        low: 300_000_000, high: 1_200_000_000))
            }
        case .imageGeneration:
            // Latent (res/8)² fp16 + UNet activations + VAE decode buffer.
            let res = input.imageResolution
            let latent = Int64((res / 8) * (res / 8) * 4 * 2)
            let vae = Int64(res * res * 3 * 2)
            let unet = Int64(res * res * 4 * 2) // peak intermediate feature map
            components.append(.init(name: "Diffusion Buffers",
                                    low: latent + vae, high: latent + vae + unet))
        case .videoGeneration, .videoUnderstanding:
            let res = input.imageResolution
            let frame = Int64(res * res * 3 * 2)
            let frames = Int64(max(1, input.videoFrames))
            components.append(.init(name: "Video Buffers",
                                    low: frame * frames / 2, high: frame * frames * 2))
        case .speechRecognition, .speechSynthesis, .audio:
            components.append(.init(name: "Audio Buffers", low: 50_000_000, high: 200_000_000))
        default:
            break
        }

        // MARK: Total with safety margin.
        let rawLow = components.reduce(Int64(0)) { $0 + $1.low }
        let rawHigh = components.reduce(Int64(0)) { $0 + $1.high }
        let low = Int64(Double(rawLow) * (1 + safetyMarginLow))
        let high = Int64(Double(rawHigh) * (1 + safetyMarginHigh))

        let confidence: MemoryEstimate.Confidence
        if weights.low > 0 && hints?.numLayers != nil && unknowns == 0 {
            confidence = .high
        } else if weights.low > 0 && unknowns <= 2 {
            confidence = .medium
        } else {
            confidence = .low
        }

        return MemoryEstimate(low: low, high: high, components: components,
                              confidence: confidence, contextLength: input.contextLength)
    }
}
