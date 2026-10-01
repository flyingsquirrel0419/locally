import Foundation
import LocallyCore

/// Pure registry of VLM architectures the app can serve, kept in the
/// package so compatibility checks are testable on Linux. The list mirrors
/// `VLMTypeRegistry.shared`'s creators map in mlx-swift-lm 3.31.4
/// (Libraries/MLXVLM/VLMModelFactory.swift) — update it when the pin moves.
public enum VLMTypeRegistry {

    /// One known VLM family.
    public struct KnownType: Sendable, Hashable {
        /// config.json `model_type`.
        public var modelType: String
        /// Whether the processor accepts more than one image per request.
        /// Source: the model's `UserInputProcessor` — most processors loop
        /// over `input.images`; PaliGemma-style single-image processors
        /// throw `VLMError.singleImageAllowed` beyond one.
        public var supportsMultipleImages: Bool
        /// Whether the processor has a video path (asProcessedSequence).
        public var supportsVideoInput: Bool

        public init(modelType: String, supportsMultipleImages: Bool,
                    supportsVideoInput: Bool) {
            self.modelType = modelType
            self.supportsMultipleImages = supportsMultipleImages
            self.supportsVideoInput = supportsVideoInput
        }
    }

    /// Architectures (config.json `model_type`) MLXVLM 3.31.4 can
    /// instantiate, with their media-arity behavior. Keys are lowercased.
    public static let knownTypes: [KnownType] = [
        .init(modelType: "paligemma", supportsMultipleImages: false,
              supportsVideoInput: false),
        .init(modelType: "qwen2_vl", supportsMultipleImages: true,
              supportsVideoInput: true),
        .init(modelType: "qwen2_5_vl", supportsMultipleImages: true,
              supportsVideoInput: true),
        .init(modelType: "qwen3_vl", supportsMultipleImages: true,
              supportsVideoInput: true),
        .init(modelType: "qwen3_5", supportsMultipleImages: true,
              supportsVideoInput: true),
        .init(modelType: "qwen3_5_moe", supportsMultipleImages: true,
              supportsVideoInput: true),
        .init(modelType: "idefics3", supportsMultipleImages: true,
              supportsVideoInput: false),
        .init(modelType: "gemma3", supportsMultipleImages: true,
              supportsVideoInput: false),
        .init(modelType: "gemma4", supportsMultipleImages: true,
              supportsVideoInput: true),
        .init(modelType: "gemma4_unified", supportsMultipleImages: true,
              supportsVideoInput: true),
        .init(modelType: "smolvlm", supportsMultipleImages: true,
              supportsVideoInput: true),
        .init(modelType: "fastvlm", supportsMultipleImages: false,
              supportsVideoInput: false),
        .init(modelType: "llava_qwen2", supportsMultipleImages: false,
              supportsVideoInput: false),
        .init(modelType: "pixtral", supportsMultipleImages: true,
              supportsVideoInput: false),
        .init(modelType: "mistral3", supportsMultipleImages: true,
              supportsVideoInput: false),
        .init(modelType: "lfm2_vl", supportsMultipleImages: true,
              supportsVideoInput: false),
        .init(modelType: "lfm2-vl", supportsMultipleImages: true,
              supportsVideoInput: false),
        .init(modelType: "glm_ocr", supportsMultipleImages: false,
              supportsVideoInput: false),
    ]

    public static func lookup(_ modelType: String) -> KnownType? {
        let key = modelType.lowercased()
        return knownTypes.first { $0.modelType == key }
    }

    /// Maximum images a single request should carry for this model type
    /// (nil/unknown → 1). Bounded by an app-level ceiling so a chat with
    /// 30 photos can't enqueue an unbounded prompt.
    public static func maxImagesPerRequest(for modelType: String?) -> Int {
        guard let modelType, let known = lookup(modelType) else { return 1 }
        return known.supportsMultipleImages ? 4 : 1
    }

    /// Whether the model family accepts video (frame-sequence) input.
    public static func supportsVideoInput(for modelType: String?) -> Bool {
        guard let modelType else { return false }
        return lookup(modelType)?.supportsVideoInput ?? false
    }

    /// Rate a model's compatibility with the MLXVLM stack, independent of
    /// device capabilities (those are layered on by the runtime).
    public static func rate(modality: ModelModality, formats: [ModelFormat],
                            architecture: String?) -> CompatibilityRating {
        guard modality == .visionLanguage || modality == .imageUnderstanding
                || modality == .videoUnderstanding else {
            return .unsupported(reason:
                "VLM runtime handles vision-language models; \(modality.rawValue) is not supported here")
        }
        guard formats.isEmpty || formats.contains(.mlx) else {
            return .unsupported(reason: "model is not in MLX format")
        }
        guard let architecture, !architecture.isEmpty else {
            return .risky(reason: "model architecture unknown; MLXVLM may not run it")
        }
        if lookup(architecture) != nil { return .supported }
        return .unsupported(reason:
            "model_type '\(architecture)' is not in the MLXVLM 3.31.4 supported list")
    }
}
