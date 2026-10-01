import Foundation
import LocallyCore

/// Bridges the image preprocessing planner into compatibility checks: given
/// the images a user intends to send, produce the planner's per-image plan
/// and a conservative working-memory estimate for the vision side of a run.
/// The heavyweight model-side accounting (vision encoder weights, decoded
/// buffers) already lives in `MemoryEstimator` (modality extras for
/// `.visionLanguage` / `.videoUnderstanding`); this probe contributes the
/// per-request image side so the UI can warn before a 12-megapixel photo
/// is fed to a 2B VLM.
public struct VisionCompatibilityProbe: Sendable {

    /// Summary for one planned request.
    public struct RequestEstimate: Sendable, Hashable {
        /// Per-image plans, one per source image.
        public var plans: [ImagePreprocessingPlanner.Plan]
        /// Sum of estimated image tokens across all images.
        public var totalEstimatedTokens: Int
        /// Sum of decoded RGBA buffer bytes across all images (the peak
        /// pre-encode footprint if all are resident at once).
        public var totalBufferBytes: Int64
        /// True when any source exceeded the planner's long-edge cap and
        /// will be downsampled before inference.
        public var anyDownsampled: Bool
    }

    public var planner: ImagePreprocessingPlanner

    public init(planner: ImagePreprocessingPlanner = ImagePreprocessingPlanner()) {
        self.planner = planner
    }

    /// Plan every image in the request against the model's preprocessor
    /// config. Images that fail planning (degenerate aspect ratio, zero
    /// size) are dropped from the estimate — the caller surfaces the error
    /// for that image separately.
    public func estimate(
        sources: [ImagePreprocessingPlanner.PixelSize],
        config: ImagePreprocessingPlanner.ProcessorConfig
    ) -> RequestEstimate {
        var plans: [ImagePreprocessingPlanner.Plan] = []
        var anyDownsampled = false
        for source in sources {
            guard let plan = try? planner.plan(source: source, config: config) else { continue }
            if plan.target.pixels < source.pixels { anyDownsampled = true }
            plans.append(plan)
        }
        return RequestEstimate(
            plans: plans,
            totalEstimatedTokens: plans.reduce(0) { $0 + $1.estimatedTokens },
            totalBufferBytes: plans.reduce(0) { $0 + $1.bufferBytes },
            anyDownsampled: anyDownsampled)
    }

    /// Whether `totalEstimatedTokens` plus a text prompt plausibly fits the
    /// model's context. Conservative: only refuses when both numbers are
    /// known and clearly exceed the context (with a 256-token completion
    /// reserve).
    public static func fitsContext(estimate: RequestEstimate,
                                   promptTokens: Int,
                                   contextLength: Int?) -> Bool {
        guard let contextLength else { return true }
        return estimate.totalEstimatedTokens + promptTokens + 256 <= contextLength
    }
}
