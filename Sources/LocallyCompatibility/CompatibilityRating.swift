import Foundation
import LocallyCore
import LocallyDevice

/// Verdict for whether a model fits a device. Full memory estimation
/// arrives in a later week; this is the shared verdict vocabulary.
public enum CompatibilityRating: String, Codable, Sendable, Hashable, CaseIterable {
    case excellent
    case good
    case marginal
    case unlikely
    case incompatible
    case unknown
}

/// Headroom-based rating rule shared by UI and engine. `headroomBytes` is
/// (budget - required). Ratings use required size ratios, not absolutes.
public enum CompatibilityRule {
    public static func rate(requiredBytes: Int64, budgetBytes: UInt64) -> CompatibilityRating {
        guard requiredBytes > 0, budgetBytes > 0 else { return .unknown }
        let required = Double(requiredBytes)
        let budget = Double(budgetBytes)
        let ratio = required / budget
        switch ratio {
        case ..<0.5: return .excellent
        case ..<0.75: return .good
        case ..<0.95: return .marginal
        case ..<1.1: return .unlikely
        default: return .incompatible
        }
    }

    public static func rate(descriptor: ModelDescriptor, profile: DeviceProfile) -> CompatibilityRating {
        guard let required = descriptor.estimatedRuntimeMemory ?? descriptor.estimatedWeightMemory,
              let budget = profile.recommendedMaxWorkingSet
        else { return .unknown }
        return rate(requiredBytes: required, budgetBytes: budget)
    }
}
