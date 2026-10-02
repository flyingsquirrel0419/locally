import Foundation
import LocallyCore

/// A relative, internal 0–<1000 score summarizing this device's suitability
/// for local AI workloads. It is NOT a scientific cross-device benchmark:
/// it is normalized against a documented reference baseline
/// (see DECISIONS.md) and intended only to compare configurations of the
/// same benchmark version. The scale is deliberately non-saturating:
/// 1000 × raw/(raw+1), so the reference device (raw == 1) lands at 500 and
/// the score approaches — never reaches — 1000 as raw grows. The previous
/// linear 0–1000 scale clamped at 1000, so every device since the
/// A14-class reference saturated at exactly 1000.
public struct AIPerformanceIndex: Codable, Sendable, Hashable {
    /// Reference baseline: roughly an A14-class device.
    public static let referenceCPUGFLOPS: Double = 10.0
    public static let referenceMemoryGBps: Double = 30.0
    public static let referenceMetalGFLOPS: Double = 500.0

    public var score: Int
    public var cpuComponent: Double
    public var memoryComponent: Double
    public var metalComponent: Double?
    public var memoryBonusGB: Double

    public init(
        score: Int,
        cpuComponent: Double,
        memoryComponent: Double,
        metalComponent: Double?,
        memoryBonusGB: Double
    ) {
        self.score = score
        self.cpuComponent = cpuComponent
        self.memoryComponent = memoryComponent
        self.metalComponent = metalComponent
        self.memoryBonusGB = memoryBonusGB
    }

    /// Compute the index from measured results plus device memory.
    /// Returns nil when no metrics were measured at all.
    public static func compute(
        benchmark: BenchmarkResult,
        physicalMemory: UInt64
    ) -> AIPerformanceIndex? {
        guard benchmark.cpuGflops != nil || benchmark.memoryCopyGBps != nil
                || benchmark.metalGflops != nil else { return nil }

        let cpu = (benchmark.cpuGflops ?? 0) / referenceCPUGFLOPS
        let mem = (benchmark.memoryCopyGBps ?? 0) / referenceMemoryGBps
        let metal = benchmark.metalGflops.map { $0 / referenceMetalGFLOPS }
        let memoryGB = Double(physicalMemory) / 1e9
        // Up to 1.5x scaling for 8GB+, logarithmic so 128GB doesn't explode.
        let memoryBonus = min(1.5, max(0.25, log2(memoryGB + 1) / log2(9)))

        // Weighted: CPU 40%, memory bandwidth 30%, GPU 30% (redistributed when
        // Metal is unavailable).
        let raw: Double
        if let metal {
            raw = (cpu * 0.4 + mem * 0.3 + metal * 0.3) * memoryBonus
        } else {
            raw = (cpu * 0.55 + mem * 0.45) * memoryBonus
        }
        // Non-saturating map: raw == 1 (reference) → 500, 3× → 750,
        // 10× → 909; 1000 is an unreachable asymptote for finite input, so
        // newer devices always outscore the reference instead of pinning at
        // a 1000 ceiling.
        let score = Int((1000.0 * raw / (raw + 1)).rounded())
        return AIPerformanceIndex(
            score: max(0, min(999, score)),
            cpuComponent: cpu,
            memoryComponent: mem,
            metalComponent: metal,
            memoryBonusGB: memoryGB
        )
    }
}
