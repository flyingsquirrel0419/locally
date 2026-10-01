import Foundation
import LocallyCore
import LocallyDevice

/// Expected decode speed, sourced only from data. A precise-looking number
/// with no measurement behind it is never produced.
public enum SpeedEstimate: Sendable, Hashable {
    /// On-device measured samples exist for this model (tokens/second range
    /// from recorded min–max).
    case measured(low: Double, high: Double)
    /// Bandwidth-bound estimate from the device's measured memory throughput.
    case estimated(low: Double, high: Double)
    case unknown

    public var label: String {
        switch self {
        case .measured: return "Measured"
        case .estimated: return "Estimated"
        case .unknown: return "Unknown"
        }
    }

    public var range: (low: Double, high: Double)? {
        switch self {
        case .measured(let l, let h), .estimated(let l, let h): return (l, h)
        case .unknown: return nil
        }
    }
}

public enum SpeedEstimator: Sendable {
    /// Source order: (a) measured on-device benchmarks for the model,
    /// (b) bandwidth-bound estimate from the device benchmark's measured
    /// memory GB/s, (c) unknown.
    public static func estimate(
        descriptor: ModelDescriptor,
        benchmarks: [InferenceMetadata],
        deviceBenchmark: BenchmarkResult?
    ) -> SpeedEstimate {
        // (a) Real samples for this model on this device.
        let samples = benchmarks.compactMap(\.tokensPerSecond).filter { $0 > 0 }
        if !samples.isEmpty {
            let lo = samples.min() ?? 0
            let hi = samples.max() ?? 0
            return .measured(low: lo, high: max(hi, lo))
        }

        // (b) Bandwidth-bound: decode reads the full weight set per token.
        // tok/s ≈ effective bandwidth / bytes-per-token. Real systems reach
        // ~60–80% of copy bandwidth, so report that as the range.
        guard let bandwidthGBps = deviceBenchmark?.memoryCopyGBps, bandwidthGBps > 0 else {
            return .unknown
        }
        let bytesPerToken: Int64?
        if let weights = descriptor.estimatedWeightMemory, weights > 0 {
            bytesPerToken = weights
        } else if let params = descriptor.parameterCount {
            let overhead = MemoryEstimator.quantOverheadFactor(descriptor.quantization)
            let bytes = Double(params) * (descriptor.quantization?.bytesPerParameter ?? 2.0)
            bytesPerToken = Int64(bytes * overhead.high)
        } else {
            bytesPerToken = nil
        }
        guard let bytes = bytesPerToken, bytes > 0 else { return .unknown }

        let bytesPerSecond = bandwidthGBps * 1e9
        let ideal = bytesPerSecond / Double(bytes)
        // Efficiency band 0.5–0.8 of the ideal bandwidth bound.
        return .estimated(low: ideal * 0.5, high: ideal * 0.8)
    }
}
