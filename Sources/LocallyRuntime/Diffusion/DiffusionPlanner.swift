import Foundation
import LocallyCore

/// Pure planning/validation for image generation on Core ML diffusion
/// models. No Core ML imports — this is fully testable on Linux; the
/// App-side DiffusionRuntime consumes the plan.
public struct DiffusionPlanner: Sendable {

    /// User-facing generation request, pre-validation.
    public struct Request: Sendable, Hashable {
        public var prompt: String
        public var negativePrompt: String
        public var stepCount: Int
        /// nil means "pick a random seed"; the plan records the seed used so
        /// the UI can display it for reproducibility.
        public var seed: UInt32?
        public var guidanceScale: Double
        public var imageCount: Int

        public init(prompt: String, negativePrompt: String = "",
                    stepCount: Int = 20, seed: UInt32? = nil,
                    guidanceScale: Double = 7.5, imageCount: Int = 1) {
            self.prompt = prompt
            self.negativePrompt = negativePrompt
            self.stepCount = stepCount
            self.seed = seed
            self.guidanceScale = guidanceScale
            self.imageCount = imageCount
        }
    }

    /// A validated request plus the context the runtime/UI need.
    public struct Plan: Sendable, Hashable {
        public var prompt: String
        public var negativePrompt: String
        public var stepCount: Int
        public var seed: UInt32
        /// `true` when the seed was randomized because none was requested.
        public var seedWasRandom: Bool
        public var guidanceScale: Float
        public var imageCount: Int
        /// The model's fixed native resolution (Core ML compiled shape).
        public var resolution: Int
        public var attention: String
        /// Estimated peak memory in bytes (weights + latents/workspace).
        public var estimatedMemoryBytes: Int64?
        /// Non-fatal advisories the UI should surface (e.g. high step count).
        public var warnings: [String]
    }

    public enum PlanError: Error, Sendable, Equatable {
        case emptyPrompt
        case stepCountOutOfRange(Int)
        case guidanceOutOfRange(Double)
        case imageCountOutOfRange(Int)
        case notADiffusionModel
        case missingResources
        /// Non-Core ML diffusion (safetensors UNet) cannot run.
        case needsCoreMLConversion
    }

    public static let stepRange = 1...50
    public static let guidanceRange = 1.0...20.0
    public static let imageCountRange = 1...4

    public init() {}

    /// Diffusion-specific knobs that don't fit GenerationParameters: the
    /// playground sends them through `ModelDescriptor.metadata` overrides.
    public static let negativePromptMetadataKey = "imagegen_negative"
    public static let guidanceMetadataKey = "imagegen_guidance"

    /// Validate a request against a model descriptor. Throws PlanError on
    /// invalid input; returns a Plan with a concrete seed and warnings.
    public func plan(_ request: Request, for model: ModelDescriptor,
                     physicalMemory: UInt64? = nil,
                     randomSource: () -> UInt32 = { UInt32.random(in: 1...UInt32.max) }
    ) throws -> Plan {
        guard model.modality == .imageGeneration else {
            throw PlanError.notADiffusionModel
        }
        // The analyzer marks safetensors-only diffusion repos unsupported;
        // enforce the same line here so a hand-built descriptor can't slip
        // through to the runtime.
        if model.metadata["unsupported_reason"] != nil,
           model.metadata["diffusion_form"] == nil {
            throw PlanError.needsCoreMLConversion
        }
        guard model.metadata["diffusion_resources_dir"] != nil
            || model.formats.contains(.coreml) else {
            throw PlanError.missingResources
        }

        let trimmed = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PlanError.emptyPrompt }
        guard Self.stepRange.contains(request.stepCount) else {
            throw PlanError.stepCountOutOfRange(request.stepCount)
        }
        guard Self.guidanceRange.contains(request.guidanceScale) else {
            throw PlanError.guidanceOutOfRange(request.guidanceScale)
        }
        guard Self.imageCountRange.contains(request.imageCount) else {
            throw PlanError.imageCountOutOfRange(request.imageCount)
        }

        let resolution = model.architectureHints?.diffusionResolution
            ?? Int(model.metadata["diffusion_resolution"] ?? "") ?? 512
        let attention = model.metadata["diffusion_attention"] ?? "split_einsum"

        var warnings: [String] = []
        if resolution >= 1024 {
            warnings.append("This model generates at 1024×1024; on devices with less than 8 GB of memory it is likely to be very slow or fail.")
        }
        if request.stepCount > 30 {
            warnings.append("\(request.stepCount) steps is slow on-device; 20 is a good default for this model.")
        }
        if let memory = physicalMemory, memory < 8 * 1024 * 1024 * 1024, resolution >= 1024 {
            warnings.append("This device has under 8 GB of memory; a 1024×1024 model is not recommended.")
        }

        let seed = request.seed ?? randomSource()
        return Plan(
            prompt: trimmed,
            negativePrompt: request.negativePrompt,
            stepCount: request.stepCount,
            seed: seed,
            seedWasRandom: request.seed == nil,
            guidanceScale: Float(request.guidanceScale),
            imageCount: request.imageCount,
            resolution: resolution,
            attention: attention,
            estimatedMemoryBytes: estimateMemory(model: model, resolution: resolution),
            warnings: warnings
        )
    }

    /// Peak-memory estimate: on-disk .mlmodelc weights (Core ML maps them
    /// into memory) plus latent buffers and a workspace allowance. Returns
    /// nil when the weight sizes are unknown — callers must not invent a
    /// number.
    public func estimateMemory(model: ModelDescriptor, resolution: Int) -> Int64? {
        guard let weights = model.estimatedWeightMemory ?? model.totalDownloadSize,
              weights > 0 else { return nil }
        // Latents: imageCount handled by caller; one latent is 4 channels at
        // resolution/8, fp32, doubled for CFG. Add a fixed workspace for
        // intermediate UNet activations (heuristic, labeled estimate).
        let latentSide = Int64(resolution / 8)
        let latentBytes = latentSide * latentSide * 4 * 4 * 2
        let workspace: Int64 = 256 * 1024 * 1024
        return weights + latentBytes + workspace
    }
}
