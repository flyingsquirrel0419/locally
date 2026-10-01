import Foundation

/// Streaming events emitted by a runtime while handling a request.
///
/// Stream contract: a run yields `.started`, then any number of progress /
/// content events, then EXACTLY ONE terminal event — `.completed` or
/// `.failed` — after which the stream finishes. Consumers can rely on no
/// events arriving after the terminal one; tests assert this invariant via
/// `assertExactlyOneTerminalEvent` in LocallyRuntimeTests.
public enum AIEvent: Sendable, Hashable {
    case started(requestID: UUID)
    /// The runtime is working on a non-streaming step (prompt load, model
    /// warmup). `phase` is a short machine-readable label.
    case preparing(String /* phase */)
    case progress(Double, phase: String?)
    case token(String)
    case partialText(String)
    case image(Data)
    case audio(Data)
    /// One answered decision question. The decision runtime emits one per
    /// question, followed by a single terminal `.completed`.
    case decision(DecisionResult)
    /// Intermediate performance counters; the terminal `.completed` result
    /// also carries the final metadata.
    case metadata(InferenceMetadata)
    case completed(result: AIResult)
    case failed(LocallyError)

    /// `true` for the events that end a stream (`.completed` / `.failed`).
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed: return true
        default: return false
        }
    }
}

/// Final output of a completed request.
public struct AIResult: Sendable, Hashable {
    public var requestID: UUID
    public var text: String?
    public var artifacts: [Artifact]
    public var metadata: InferenceMetadata

    public enum Artifact: Sendable, Hashable {
        case image(Data)
        case audio(Data)
        case video(Data)
        case decision(DecisionResult)
    }

    public init(
        requestID: UUID,
        text: String? = nil,
        artifacts: [Artifact] = [],
        metadata: InferenceMetadata = InferenceMetadata()
    ) {
        self.requestID = requestID
        self.text = text
        self.artifacts = artifacts
        self.metadata = metadata
    }
}

/// A small JSON-ish value used by the on-device decision runtime.
public enum JSONValue: Codable, Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let b = try? container.decode(Bool.self) { self = .bool(b); return }
        if let n = try? container.decode(Double.self) { self = .number(n); return }
        if let s = try? container.decode(String.self) { self = .string(s); return }
        if let a = try? container.decode([JSONValue].self) { self = .array(a); return }
        self = .object(try container.decode([String: JSONValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        case .null: try container.encodeNil()
        }
    }
}

/// One answered question from the decision runtime: key plus JSON-ish value
/// plus the metadata needed to trust and debug the answer.
public struct DecisionResult: Codable, Sendable, Hashable {
    /// How the answer was produced.
    public enum Method: String, Codable, Sendable, Hashable {
        /// Token log-probability scoring over candidates (calibrated).
        case scored
        /// Free-text generation validated against the question's output
        /// schema (uncalibrated; `probabilities` stays nil).
        case generated
    }

    public var key: String
    public var value: JSONValue
    /// The question type this value answers, when known ("choice", "boolean",
    /// "probability", "noul", "score", "ranking", "structured").
    public var type: String?
    /// Per-candidate probabilities for scored answers (choice/boolean/noul/
    /// score/ranking); nil for generated output, which is not calibrated.
    public var probabilities: [String: Double]?
    public var method: Method?
    /// Raw model text for debugging. Never logged.
    public var rawText: String?

    public init(key: String, value: JSONValue, type: String? = nil,
                probabilities: [String: Double]? = nil, method: Method? = nil,
                rawText: String? = nil) {
        self.key = key
        self.value = value
        self.type = type
        self.probabilities = probabilities
        self.method = method
        self.rawText = rawText
    }
}

/// Performance counters for a single inference run. Fields stay nil until
/// real measurement exists; nothing here is fabricated.
public struct InferenceMetadata: Codable, Sendable, Hashable {
    public var loadTime: TimeInterval?
    public var ttft: TimeInterval?
    public var tokensPerSecond: Double?
    public var generatedTokens: Int?
    /// Approximate process resident memory sampled at end of run. The
    /// llama.cpp C API does not expose a per-model counter, so this reads
    /// process-level RSS (Linux /proc/self/statm) or physical footprint
    /// (Apple task_info); it covers the whole process, not just the model.
    public var peakMemoryBytes: Int64?

    public init(
        loadTime: TimeInterval? = nil,
        ttft: TimeInterval? = nil,
        tokensPerSecond: Double? = nil,
        generatedTokens: Int? = nil,
        peakMemoryBytes: Int64? = nil
    ) {
        self.loadTime = loadTime
        self.ttft = ttft
        self.tokensPerSecond = tokensPerSecond
        self.generatedTokens = generatedTokens
        self.peakMemoryBytes = peakMemoryBytes
    }
}
