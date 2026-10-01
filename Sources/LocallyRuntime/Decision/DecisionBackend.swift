import Foundation
import LocallyCore

/// A backend that can score candidate continuations by token log-probability.
/// This is the calibrated path: candidates are short strings ("yes", "no",
/// option labels, numeric tokens) and the returned value is the summed
/// log-probability of each candidate's tokens given the prompt.
///
/// A llama.cpp implementation lands in LlamaBridge in the integration step;
/// any sampler exposing per-token logprobs can implement this protocol.
public protocol TokenScoringBackend: Sendable {
    /// Sum of token log-probabilities of each candidate continuation, aligned
    /// with `candidates` order.
    func logProbabilities(prompt: String, candidates: [String]) async throws -> [Double]
}

/// Fallback backend: free-text generation under a strict prompt, validated
/// against the question's output schema. Uncalibrated — probabilities are
/// not available from this path.
public protocol TextGenerationBackend: Sendable {
    /// Generate text for a fully-rendered prompt. Temperature is always 0.
    func generate(prompt: String, maxTokens: Int) async throws -> String
}

/// Deterministic scoring backend for tests. Candidates are scored by exact
/// lookup; unknown candidates get `defaultLogProb`.
public struct MockScoringBackend: TokenScoringBackend {
    public var scores: [String: Double]
    public var defaultLogProb: Double

    public init(scores: [String: Double] = [:], defaultLogProb: Double = -10) {
        self.scores = scores
        self.defaultLogProb = defaultLogProb
    }

    public func logProbabilities(prompt: String, candidates: [String]) async throws -> [Double] {
        candidates.map { scores[$0] ?? defaultLogProb }
    }
}

/// Deterministic generation backend for tests. Each call pops the next
/// queued response; when the queue is empty it replays the last one (which
/// is what retry-on-invalid exercises).
public struct MockGenerationBackend: TextGenerationBackend {
    private struct State {
        var prompts: [String] = []
        var responses: [String]
    }
    private let state: LockedState<State>

    public init(responses: [String]) {
        self.state = LockedState(State(responses: responses))
    }

    public var prompts: [String] { state.withLock { $0.prompts } }

    public func generate(prompt: String, maxTokens: Int) async throws -> String {
        state.withLock { s in
            s.prompts.append(prompt)
            if s.responses.count > 1 { return s.responses.removeFirst() }
            return s.responses.first ?? ""
        }
    }
}

/// Adapts any existing AIRuntime text runtime (e.g. GGUFRuntime) into a
/// TextGenerationBackend by consuming its token stream. This is what makes
/// the decision runtime work today via the generation path, before a native
/// llama.cpp scoring backend exists.
public struct GenerationBackendAdapter: TextGenerationBackend {
    public let runtime: any AIRuntime
    public let model: ModelDescriptor

    public init(runtime: any AIRuntime, model: ModelDescriptor) {
        self.runtime = runtime
        self.model = model
    }

    public func generate(prompt: String, maxTokens: Int) async throws -> String {
        let request = AIRequest(
            model: model,
            input: .text(prompt),
            parameters: GenerationParameters(
                temperature: 0, topP: 1.0, maxTokens: maxTokens))
        var text = ""
        var failure: LocallyError?
        for try await event in runtime.run(request) {
            switch event {
            case .token(let piece), .partialText(let piece):
                text += piece
            case .completed(let result):
                if let finalText = result.text { text = finalText }
            case .failed(let error):
                failure = error
            default:
                break
            }
        }
        if let failure { throw failure }
        return text
    }
}

/// Errors from the decision engine.
public enum DecisionError: Error, Sendable, Hashable {
    /// Model output failed schema validation after the retry budget.
    /// `userMessage` is safe to show; `detail` is diagnostic only.
    case invalidOutput(userMessage: String, detail: String)
    /// The backend failed (load error, inference error, cancellation).
    case backendFailed(userMessage: String, detail: String)

    public var locallyError: LocallyError {
        switch self {
        case .invalidOutput(let userMessage, let detail):
            return .inferenceFailed(userMessage: userMessage, technicalDetail: detail)
        case .backendFailed(let userMessage, let detail):
            return .inferenceFailed(userMessage: userMessage, technicalDetail: detail)
        }
    }
}
