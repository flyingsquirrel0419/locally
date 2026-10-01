import Foundation
import LocallyCore
import LocallyDevice

/// Picks context lengths that fit a device budget.
public struct ContextRecommender: Sendable {
    public static let candidates = [2_048, 4_096, 8_192, 16_384, 32_768, 65_536, 131_072]

    public var estimator: MemoryEstimator

    public init(estimator: MemoryEstimator = MemoryEstimator()) {
        self.estimator = estimator
    }

    public struct Recommendation: Sendable, Hashable {
        /// Largest candidate whose high estimate fits the safe budget.
        public var recommended: Int?
        /// Largest candidate whose low estimate fits the budget at all.
        public var maximumEstimated: Int?
        /// The model's own context ceiling.
        public var modelMaximum: Int?

        public init(recommended: Int?, maximumEstimated: Int?, modelMaximum: Int?) {
            self.recommended = recommended
            self.maximumEstimated = maximumEstimated
            self.modelMaximum = modelMaximum
        }
    }

    public func recommend(descriptor: ModelDescriptor, budgetBytes: UInt64,
                          runtime: RuntimeKind? = nil) -> Recommendation {
        let modelMax = descriptor.contextLength
        guard budgetBytes > 0 else {
            return Recommendation(recommended: nil, maximumEstimated: nil, modelMaximum: modelMax)
        }
        let cap = modelMax ?? Self.candidates.last ?? 131_072
        let options = Self.candidates.filter { $0 <= cap }
        guard !options.isEmpty else {
            return Recommendation(recommended: nil, maximumEstimated: nil, modelMaximum: modelMax)
        }

        var recommended: Int?
        var maximum: Int?
        for context in options {
            let estimate = estimator.estimate(.init(descriptor: descriptor,
                                                    contextLength: context,
                                                    runtime: runtime))
            if estimate.low <= Int64(budgetBytes) { maximum = context }
            if estimate.high <= Int64(budgetBytes) { recommended = context }
        }
        return Recommendation(recommended: recommended, maximumEstimated: maximum,
                              modelMaximum: modelMax)
    }
}
