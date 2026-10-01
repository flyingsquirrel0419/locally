import Foundation
import LocallyCore

/// How well a runtime can serve a given model on this device.
public enum CompatibilityRating: Sendable, Hashable, Comparable {
    case unsupported(reason: String)
    /// Might work but is not confirmed for this model (e.g. unknown arch).
    case risky(reason: String)
    case supported

    public static func < (lhs: CompatibilityRating, rhs: CompatibilityRating) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .unsupported: return 0
        case .risky: return 1
        case .supported: return 2
        }
    }
}

/// A runtime that can report how compatible it is with a model.
public protocol ModelCompatibleRuntime: AIRuntime {
    func compatibility(with model: ModelDescriptor, on device: DeviceCapabilities) -> CompatibilityRating
}

/// Picks a runtime for a model: highest compatibility rating wins; ties
/// break on preference order. All decisions carry an honest reason.
public struct RuntimeRouter: Sendable {
    public struct Decision: Sendable, Hashable {
        public var runtimeKind: RuntimeKind?
        public var rating: CompatibilityRating
        public var reason: String

        public var isRunnable: Bool { runtimeKind != nil }
    }

    public let runtimes: [any ModelCompatibleRuntime]

    public init(runtimes: [any ModelCompatibleRuntime]) {
        self.runtimes = runtimes
    }

    public func decide(for model: ModelDescriptor, on device: DeviceCapabilities) -> Decision {
        var best: (runtime: any ModelCompatibleRuntime, rating: CompatibilityRating)?
        var reasons: [String] = []
        for runtime in runtimes {
            let rating = runtime.compatibility(with: model, on: device)
            reasons.append("\(runtime.kind.rawValue): \(describe(rating))")
            if case .unsupported = rating { continue }
            if best == nil || rating > best!.rating {
                best = (runtime, rating)
            }
        }
        if let best {
            return Decision(runtimeKind: best.runtime.kind, rating: best.rating,
                            reason: describe(best.rating))
        }
        return Decision(runtimeKind: nil, rating: .unsupported(reason: reasons.joined(separator: "; ")),
                        reason: reasons.isEmpty ? "no runtimes registered" : reasons.joined(separator: "; "))
    }

    public func runtime(for model: ModelDescriptor, on device: DeviceCapabilities) -> (any ModelCompatibleRuntime)? {
        let decision = decide(for: model, on: device)
        guard let kind = decision.runtimeKind else { return nil }
        return runtimes.first { $0.kind == kind }
    }

    private func describe(_ rating: CompatibilityRating) -> String {
        switch rating {
        case .supported: return "supported"
        case .risky(let r): return "risky: \(r)"
        case .unsupported(let r): return "unsupported: \(r)"
        }
    }
}
