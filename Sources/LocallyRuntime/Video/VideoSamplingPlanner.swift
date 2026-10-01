import Foundation
import LocallyCore

/// Pure planner for video understanding: decides how many frames to sample,
/// at which timestamps, in which batches, and how large each frame should
/// be — given the video duration, device pressure signals, and the active
/// VLM's limits. No AVFoundation here; fully testable on Linux.
public struct VideoSamplingPlanner: Sendable {

    /// Device pressure the pipeline can observe without platform types.
    public enum ThermalLevel: String, Sendable, Hashable, Comparable {
        case nominal, fair, serious, critical

        public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool {
            lhs.rank < rhs.rank
        }

        private var rank: Int {
            switch self {
            case .nominal: return 0
            case .fair: return 1
            case .serious: return 2
            case .critical: return 3
            }
        }
    }

    /// Conditions under which a plan is requested.
    public struct Context: Sendable, Hashable {
        /// Video duration in seconds.
        public var duration: TimeInterval
        /// Declared frames-per-second of the video track (unused for
        /// uniform sampling, kept for future scene-aware policies).
        public var fps: Double?
        public var thermal: ThermalLevel
        public var lowPowerMode: Bool
        /// Bytes of memory the run may use for decoded frame buffers
        /// (from the shared device budget).
        public var memoryBudgetBytes: Int64
        /// Images the active VLM accepts per request (1 for single-image
        /// models, 4 for multi-image ones).
        public var imagesPerRequest: Int
        /// Optional explicit frame-count override (8/16/32) from the UI.
        public var requestedFrameCount: Int?

        public init(duration: TimeInterval, fps: Double? = nil,
                    thermal: ThermalLevel = .nominal, lowPowerMode: Bool = false,
                    memoryBudgetBytes: Int64 = 512_000_000,
                    imagesPerRequest: Int = 1, requestedFrameCount: Int? = nil) {
            self.duration = duration
            self.fps = fps
            self.thermal = thermal
            self.lowPowerMode = lowPowerMode
            self.memoryBudgetBytes = memoryBudgetBytes
            self.imagesPerRequest = max(1, imagesPerRequest)
            self.requestedFrameCount = requestedFrameCount
        }
    }

    public enum PlanError: Error, Sendable, Hashable {
        /// Thermal state critical: refuse the run with an honest reason.
        case refusedThermal
        /// Duration is zero/negative or not finite.
        case unusableDuration
    }

    /// The planner's full answer.
    public struct Plan: Sendable, Hashable {
        /// Seconds from the start, ascending, evenly spaced (jitter-free:
        /// deterministic for a given duration/frame count).
        public var timestamps: [TimeInterval]
        /// Frames per VLM request (≤ imagesPerRequest, ≥ 1).
        public var batchSize: Int
        /// Target pixel size for every sampled frame.
        public var frameTarget: ImagePreprocessingPlanner.PixelSize
        /// Why the frame count landed where it did (for the UI footer).
        public var reason: String

        public var frameCount: Int { timestamps.count }
        /// Inclusive ranges of `timestamps` grouped into batches.
        public var batches: [[TimeInterval]] {
            stride(from: 0, to: timestamps.count, by: batchSize).map {
                Array(timestamps[$0 ..< min($0 + batchSize, timestamps.count)])
            }
        }
    }

    public var framePlanner: ImagePreprocessingPlanner

    public init(framePlanner: ImagePreprocessingPlanner = ImagePreprocessingPlanner()) {
        self.framePlanner = framePlanner
    }

    // MARK: - Frame count

    /// Duration-based adaptive count: <15 s → 8, <2 min → 16, else 32.
    /// A user override wins over the adaptive pick. Thermal and low-power
    /// pressure then shrink it (serious/low-power halve; critical refuses).
    static func adaptiveFrameCount(duration: TimeInterval) -> Int {
        switch duration {
        case ..<15: return 8
        case ..<120: return 16
        default: return 32
        }
    }

    static func pressuredFrameCount(base: Int, thermal: ThermalLevel,
                                    lowPowerMode: Bool) -> Int {
        var count = base
        if thermal == .serious { count /= 2 }
        if lowPowerMode { count /= 2 }
        // Never below 4: fewer frames makes the map-reduce answer
        // meaningless for anything but a clip.
        return max(4, count)
    }

    // MARK: - Plan

    public func plan(_ context: Context,
                     frameConfig: ImagePreprocessingPlanner.ProcessorConfig = .init()
    ) throws -> Plan {
        guard context.duration.isFinite, context.duration > 0 else {
            throw PlanError.unusableDuration
        }
        guard context.thermal != .critical else { throw PlanError.refusedThermal }

        let base = context.requestedFrameCount ?? Self.adaptiveFrameCount(duration: context.duration)
        let count = Self.pressuredFrameCount(base: base, thermal: context.thermal,
                                             lowPowerMode: context.lowPowerMode)

        let frameTarget = try frameTargetSize(config: frameConfig)
        let batchSize = Self.batchSize(imagesPerRequest: context.imagesPerRequest,
                                       frameTarget: frameTarget,
                                       memoryBudgetBytes: context.memoryBudgetBytes)
        let timestamps = Self.uniformTimestamps(duration: context.duration, count: count)

        let reason: String
        if context.thermal == .serious || context.lowPowerMode {
            reason = "reduced to \(count) frames under device pressure"
        } else if context.requestedFrameCount != nil {
            reason = "user-selected \(count) frames"
        } else {
            reason = "auto: \(count) frames for a \(Int(context.duration))s video"
        }
        return Plan(timestamps: timestamps, batchSize: batchSize,
                    frameTarget: frameTarget, reason: reason)
    }

    /// Evenly spaced timestamps across (0, duration): the midpoint of each
    /// of `count` equal segments. Deterministic — no jitter, so repeat runs
    /// sample identical frames.
    public static func uniformTimestamps(duration: TimeInterval, count: Int) -> [TimeInterval] {
        guard count > 0, duration > 0 else { return [] }
        let segment = duration / Double(count)
        return (0 ..< count).map { segment * (Double($0) + 0.5) }
    }

    /// Frames per request: the model's per-request image cap, clamped by
    /// how many decoded frame buffers fit the memory budget at once
    /// (RGBA 4 bytes/px, ×2 for the processor's working copy).
    public static func batchSize(imagesPerRequest: Int,
                                 frameTarget: ImagePreprocessingPlanner.PixelSize,
                                 memoryBudgetBytes: Int64) -> Int {
        let perFrame = Int64(frameTarget.pixels) * 4 * 2
        guard perFrame > 0 else { return 1 }
        let affordable = max(1, Int(memoryBudgetBytes / 4 / perFrame))
        return max(1, min(imagesPerRequest, affordable))
    }

    /// Per-frame target size: the frame planner's answer for a landscape
    /// 16:9 reference frame, so all batches share one fixed budget.
    public func frameTargetSize(
        config: ImagePreprocessingPlanner.ProcessorConfig
    ) throws -> ImagePreprocessingPlanner.PixelSize {
        let reference = ImagePreprocessingPlanner.PixelSize(width: 1920, height: 1080)
        return try framePlanner.plan(source: reference, config: config).target
    }
}
