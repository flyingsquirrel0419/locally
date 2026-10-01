import Foundation
import LocallyCore

#if canImport(CLlama) || canImport(llama)

/// llama.cpp implementation of `TokenScoringBackend`: the calibrated path
/// for the decision runtime. Each call tokenizes the prompt once, decodes
/// it, and scores candidates against the cached prompt via log-softmax over
/// the vocab (see LlamaBridge.scoreCandidates).
///
/// The backend manages its own decode context per call: it ends any active
/// generation context first, then begins a scoring context sized to the
/// prompt plus the longest candidate, and ends it when done. A generation
/// `run` that follows re-creates its own context, so the two never overlap.
public struct LlamaTokenScoringBackend: TokenScoringBackend, Sendable {
    private let bridge: LlamaBridge

    /// Internal: constructed only via `GGUFRuntime.makeScoringBackend()`.
    init(bridge: LlamaBridge) {
        self.bridge = bridge
    }

    public func logProbabilities(prompt: String, candidates: [String]) async throws -> [Double] {
        guard !candidates.isEmpty else { return [] }
        // Context budget: prompt tokens + longest candidate + margin.
        // Tokenizing here (once, on the bridge) sizes the context so scoring
        // never hits a hard n_ctx limit mid-candidate.
        let promptTokens = try await bridge.tokenize(prompt, addSpecial: true)
        var longestCandidate = 0
        for candidate in candidates {
            let tokens = try await bridge.tokenize(" \(candidate)", addSpecial: false)
            longestCandidate = max(longestCandidate, tokens.count)
        }
        let needed = promptTokens.count + longestCandidate + 8
        await bridge.endContext()
        do {
            try await bridge.beginContext(maxContext: needed)
            let scores = try await bridge.scoreCandidates(prompt: prompt, candidates: candidates)
            await bridge.endContext()
            return scores
        } catch {
            await bridge.endContext()
            throw error
        }
    }
}

extension GGUFRuntime {
    /// A scoring backend over this runtime's llama bridge, when llama.cpp is
    /// linked and a model is loaded. DecisionRuntime prefers this path over
    /// generation because it is calibrated (per-candidate probabilities).
    public func makeScoringBackend() -> (any TokenScoringBackend)? {
        LlamaTokenScoringBackend(bridge: bridge)
    }
}

#else

extension GGUFRuntime {
    /// llama.cpp is not linked into this build; no scoring backend exists.
    public func makeScoringBackend() -> (any TokenScoringBackend)? { nil }
}

#endif
