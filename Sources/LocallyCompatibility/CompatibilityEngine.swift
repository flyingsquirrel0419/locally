import Foundation
import LocallyCore
import LocallyDevice

/// Full verdict for a (device, model) pair.
public struct CompatibilityReport: Sendable, Hashable {
    /// Week-7 rating vocabulary: how comfortably the model fits the device.
    /// Bands relative to the safe memory budget (high estimate ÷ budget):
    /// excellent < 0.45, good < 0.70, usable < 0.95, risky < 1.15,
    /// unsupported ≥ 1.15 or a hard blocker.
    public enum Rating: String, Codable, Sendable, Hashable, Comparable {
        case excellent, good, usable, risky, unsupported

        private var order: Int {
            switch self {
            case .excellent: return 0
            case .good: return 1
            case .usable: return 2
            case .risky: return 3
            case .unsupported: return 4
            }
        }

        public static func < (lhs: Rating, rhs: Rating) -> Bool {
            lhs.order < rhs.order
        }
    }

    public enum ThermalLoad: String, Codable, Sendable, Hashable {
        case low, medium, high
    }

    public var rating: Rating
    public var memory: MemoryEstimate?
    public var recommendedContext: Int?
    public var maxContext: Int?
    public var speed: SpeedEstimate
    public var thermalLoad: ThermalLoad
    public var recommendedRuntime: RuntimeKind?
    public var rankedRuntimes: [RuntimeScore]
    /// User-facing cautions that do not block the model.
    public var warnings: [String]
    /// Hard reasons the model cannot run; non-empty ⇒ rating == .unsupported.
    public var blockers: [String]

    public init(rating: Rating, memory: MemoryEstimate?, recommendedContext: Int?,
                maxContext: Int?, speed: SpeedEstimate, thermalLoad: ThermalLoad,
                recommendedRuntime: RuntimeKind?, rankedRuntimes: [RuntimeScore],
                warnings: [String], blockers: [String]) {
        self.rating = rating
        self.memory = memory
        self.recommendedContext = recommendedContext
        self.maxContext = maxContext
        self.speed = speed
        self.thermalLoad = thermalLoad
        self.recommendedRuntime = recommendedRuntime
        self.rankedRuntimes = rankedRuntimes
        self.warnings = warnings
        self.blockers = blockers
    }
}

/// Combines the memory estimator, context recommender, speed estimator and
/// runtime scorer into one verdict.
public struct CompatibilityEngine: Sendable {
    public var estimator: MemoryEstimator
    public var scorer: RuntimeScorer

    public init(estimator: MemoryEstimator = MemoryEstimator(),
                scorer: RuntimeScorer = RuntimeScorer()) {
        self.estimator = estimator
        self.scorer = scorer
    }

    public func evaluate(
        descriptor: ModelDescriptor,
        device: DeviceProfile,
        benchmarks: [InferenceMetadata] = [],
        deviceBenchmark: BenchmarkResult? = nil
    ) -> CompatibilityReport {
        var warnings: [String] = []
        var blockers: [String] = []

        // MARK: Hard blockers first.
        if descriptor.metadata["requiresRemoteCode"] == "true" {
            blockers.append("This model requires running repository code, which this app does not allow.")
        }
        if descriptor.modality == .unknown {
            blockers.append("The model's modality could not be determined.")
        }
        if descriptor.supportedRuntimes.isEmpty
            && !blockers.contains(where: { $0.contains("repository code") }) {
            blockers.append("No runtime on this device can load the model's format.")
        }
        if let downloadSize = descriptor.totalDownloadSize, downloadSize > 0,
           let free = device.freeStorage, free > 0, downloadSize > free {
            blockers.append("Not enough storage: needs \(Self.formatBytes(downloadSize)) but only \(Self.formatBytes(free)) is free.")
        }

        guard blockers.isEmpty else {
            return CompatibilityReport(
                rating: .unsupported, memory: nil, recommendedContext: nil,
                maxContext: nil, speed: .unknown, thermalLoad: .low,
                recommendedRuntime: nil,
                rankedRuntimes: scorer.score(descriptor: descriptor, memoryFitRatio: nil,
                                             metalAvailable: device.metalAvailable),
                warnings: warnings, blockers: blockers
            )
        }

        // MARK: Memory vs safe budget.
        let budget = device.recommendedMaxWorkingSet
            ?? MemoryBudget.safeAIBudget(physicalMemory: device.physicalMemory,
                                         availableEstimate: device.availableMemoryEstimate)
        let contextForEstimate = descriptor.contextLength
            ?? ContextRecommender.candidates.first { $0 >= 4_096 } ?? 4_096
        let runtime = descriptor.supportedRuntimes.first
        let memory = estimator.estimate(.init(descriptor: descriptor,
                                              contextLength: contextForEstimate,
                                              runtime: runtime))

        let recommender = ContextRecommender(estimator: estimator)
        let recommendation = recommender.recommend(descriptor: descriptor,
                                                   budgetBytes: budget,
                                                   runtime: runtime)

        let ratio = budget > 0 ? Double(memory.high) / Double(budget) : .infinity
        var rating: CompatibilityReport.Rating
        switch ratio {
        case ..<0.45: rating = .excellent
        case ..<0.70: rating = .good
        case ..<0.95: rating = .usable
        case ..<1.15: rating = .risky
        default: rating = .unsupported
        }
        if rating == .unsupported {
            blockers.append("Not enough memory: needs ~\(Self.formatBytes(memory.high)), your device can safely provide ~\(Self.formatBytes(Int64(budget))).")
        } else if rating == .risky {
            warnings.append("Tight fit: needs ~\(Self.formatBytes(memory.high)) of a ~\(Self.formatBytes(Int64(budget))) safe budget; expect pressure under load.")
        }

        if memory.confidence == .low {
            warnings.append("Memory estimate has low confidence; key architecture details are unknown.")
        }

        // MARK: Thermal & power.
        let thermalLoad = Self.thermalLoad(descriptor: descriptor, context: contextForEstimate)
        if device.lowPowerMode {
            warnings.append("Low Power Mode is on; sustained inference will be slower.")
        }
        switch device.thermalState {
        case .serious:
            warnings.append("Device is already running hot (thermal state: serious); expect throttling.")
        case .critical:
            warnings.append("Device is critically hot; wait for it to cool before running models.")
            if rating < .risky { rating = .risky }
        case .fair:
            if rating == .excellent { rating = .good }
        case .nominal:
            break
        }

        // MARK: Speed from data only.
        let speed = SpeedEstimator.estimate(descriptor: descriptor,
                                            benchmarks: benchmarks,
                                            deviceBenchmark: deviceBenchmark)

        // MARK: Runtimes.
        let ranked = scorer.score(descriptor: descriptor,
                                  memoryFitRatio: budget > 0 ? Double(memory.high) / Double(budget) : nil,
                                  metalAvailable: device.metalAvailable)
        let recommendedRuntime = ranked.first(where: { $0.availability == .available })?.runtime
        if ranked.isEmpty == false && recommendedRuntime == nil {
            warnings.append("Compatible runtimes exist but none are available in this build.")
        }

        return CompatibilityReport(
            rating: rating,
            memory: memory,
            recommendedContext: recommendation.recommended,
            maxContext: recommendation.maximumEstimated,
            speed: speed,
            thermalLoad: thermalLoad,
            recommendedRuntime: recommendedRuntime,
            rankedRuntimes: ranked,
            warnings: warnings,
            blockers: blockers
        )
    }

    /// Sustained-load heuristic: params × context gives a rough FLOPs per
    /// token trend; large models at long context push thermals.
    static func thermalLoad(descriptor: ModelDescriptor, context: Int) -> CompatibilityReport.ThermalLoad {
        guard let params = descriptor.parameterCount else { return .medium }
        let work = Double(params) * Double(max(context, 1))
        switch work {
        case ..<4e12: return .low        // ≤ ~1B @ 4K
        case ..<3e13: return .medium     // ~7B @ 4K
        default: return .high            // 7B+ @ long context
        }
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb >= 0.95 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576.0)
    }
}
