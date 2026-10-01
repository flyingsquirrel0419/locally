import Foundation

/// Streaming events emitted by a runtime while handling a request.
public enum AIEvent: Sendable, Hashable {
    case started(requestID: UUID)
    case token(String)
    case partialText(String)
    case progress(Double)
    case image(Data)
    case audio(Data)
    case completed(result: AIResult)
    case failed(LocallyError)
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

/// Placeholder result for the decision runtime: key plus JSON-ish value.
public struct DecisionResult: Codable, Sendable, Hashable {
    public var key: String
    public var value: JSONValue

    public init(key: String, value: JSONValue) {
        self.key = key
        self.value = value
    }
}

/// Performance counters for a single inference run. Fields stay nil until
/// real measurement exists; nothing here is fabricated.
public struct InferenceMetadata: Codable, Sendable, Hashable {
    public var loadTime: TimeInterval?
    public var ttft: TimeInterval?
    public var tokensPerSecond: Double?
    public var generatedTokens: Int?
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
