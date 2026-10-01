import Foundation
import LocallyCore

/// One scored runtime candidate for a model.
public struct RuntimeScore: Sendable, Hashable {
    public enum Availability: String, Sendable, Hashable {
        case available
        /// Not linked into this build (e.g. MLX not compiled in).
        case unavailable
    }

    public var runtime: RuntimeKind
    /// 0–100 composite score; higher is better. Meaningful only among
    /// candidates for the same model.
    public var score: Int
    public var availability: Availability
    /// User-facing rationale, one short phrase per contributing factor.
    public var reasons: [String]

    public init(runtime: RuntimeKind, score: Int, availability: Availability,
                reasons: [String]) {
        self.runtime = runtime
        self.score = score
        self.availability = availability
        self.reasons = reasons
    }
}

/// Ranks the runtimes a model could use. Scoring inputs: memory fit,
/// expected speed class, runtime maturity for the model's primary format,
/// and feature support for the modality.
public struct RuntimeScorer: Sendable {
    /// Called with each candidate; returns false when the runtime is not
    /// linked into this build. Defaults to everything available so the
    /// package stays testable on Linux.
    public var isRuntimeAvailable: @Sendable (RuntimeKind) -> Bool

    public init(isRuntimeAvailable: @escaping @Sendable (RuntimeKind) -> Bool = { _ in true }) {
        self.isRuntimeAvailable = isRuntimeAvailable
    }

    /// Maturity: the pairing the ecosystem actually ships for.
    static func maturity(_ runtime: RuntimeKind, formats: [ModelFormat]) -> Int {
        switch runtime {
        case .mlx: return formats.contains(.mlx) ? 30 : 5
        case .gguf: return formats.contains(.gguf) ? 30 : 5
        case .coreml: return formats.contains(.coreml) ? 25 : 5
        case .diffusion: return 20
        case .audio: return 20
        case .vision: return 15
        case .video: return 10
        case .decision: return 30
        }
    }

    /// Feature support for the modality on this runtime.
    static func modalitySupport(_ runtime: RuntimeKind, modality: ModelModality) -> Int {
        switch (runtime, modality) {
        case (.decision, .decision): return 25
        case (.diffusion, .imageGeneration): return 25
        case (.audio, .speechRecognition), (.audio, .speechSynthesis), (.audio, .audio): return 25
        case (.video, .videoUnderstanding), (.video, .videoGeneration): return 25
        case (.mlx, .text), (.gguf, .text), (.coreml, .text): return 25
        case (.mlx, .visionLanguage), (.gguf, .visionLanguage): return 20
        case (.coreml, .visionLanguage): return 15
        case (.mlx, .embedding), (.gguf, .embedding), (.coreml, .embedding): return 20
        case (.mlx, .reranker), (.gguf, .reranker), (.coreml, .reranker): return 15
        case (.coreml, .imageGeneration): return 15
        default: return 0
        }
    }

    /// Speed class expectation: Metal-backed MLX/CoreML typically outpace
    /// llama.cpp decode on Apple silicon for the same weights.
    static func speedClass(_ runtime: RuntimeKind, metalAvailable: Bool) -> Int {
        switch runtime {
        case .mlx: return metalAvailable ? 25 : 10
        case .coreml: return metalAvailable ? 22 : 10
        case .gguf: return metalAvailable ? 18 : 12
        case .diffusion: return metalAvailable ? 20 : 5
        case .audio: return metalAvailable ? 18 : 8
        case .video: return metalAvailable ? 15 : 4
        case .vision: return metalAvailable ? 18 : 8
        case .decision: return 20
        }
    }

    public func score(descriptor: ModelDescriptor, memoryFitRatio: Double?,
                      metalAvailable: Bool) -> [RuntimeScore] {
        descriptor.supportedRuntimes.map { runtime in
            var reasons: [String] = []
            var total = 0

            let fit: Int
            if let ratio = memoryFitRatio {
                switch ratio {
                case ..<0.5: fit = 20; reasons.append("fits with headroom")
                case ..<0.85: fit = 12; reasons.append("fits, limited headroom")
                default: fit = 0; reasons.append("tight on memory")
                }
            } else {
                fit = 6
                reasons.append("memory fit unknown")
            }
            total += fit

            let maturity = Self.maturity(runtime, formats: descriptor.formats)
            total += maturity
            if maturity >= 25 {
                reasons.append("native format support")
            }

            let support = Self.modalitySupport(runtime, modality: descriptor.modality)
            total += support
            if support >= 20 {
                reasons.append("supports \(descriptor.modality.rawValue)")
            } else if support == 0 {
                reasons.append("no feature support for \(descriptor.modality.rawValue)")
            }

            let speed = Self.speedClass(runtime, metalAvailable: metalAvailable)
            total += speed
            if !metalAvailable {
                reasons.append("GPU acceleration unavailable on this device")
            }

            let availability: RuntimeScore.Availability =
                isRuntimeAvailable(runtime) ? .available : .unavailable
            if availability == .unavailable {
                reasons.append("not available in this build")
                total = 0
            }

            return RuntimeScore(runtime: runtime, score: total,
                                availability: availability, reasons: reasons)
        }
        .sorted { lhs, rhs in
            if lhs.availability != rhs.availability {
                return lhs.availability == .available
            }
            return lhs.score > rhs.score
        }
    }
}
