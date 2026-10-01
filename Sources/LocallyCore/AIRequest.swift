import Foundation

/// A single piece of user input to a runtime.
public enum AIInput: Codable, Sendable, Hashable {
    case text(String)
    case image(Data)
    case audio(Data)
    case videoFrame(Data)
    case chat([ChatMessage])
    /// Structured JSON payload (e.g. a decision schema document).
    case json([String: JSONValue])

    public struct ChatMessage: Codable, Sendable, Hashable {
        public enum Role: String, Codable, Sendable, Hashable {
            case system, user, assistant, tool
        }
        public var role: Role
        public var content: String
        public init(role: Role, content: String) {
            self.role = role
            self.content = content
        }
    }
}

/// Sampling and budget knobs for generation.
public struct GenerationParameters: Codable, Sendable, Hashable {
    public var temperature: Double
    public var topP: Double
    public var topK: Int?
    public var maxTokens: Int
    public var contextLength: Int?
    public var stop: [String]
    public var seed: UInt64?

    public init(
        temperature: Double = 0.7,
        topP: Double = 0.95,
        topK: Int? = nil,
        maxTokens: Int = 512,
        contextLength: Int? = nil,
        stop: [String] = [],
        seed: UInt64? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.maxTokens = maxTokens
        self.contextLength = contextLength
        self.stop = stop
        self.seed = seed
    }
}

/// One unit of work handed to a runtime.
public struct AIRequest: Codable, Sendable, Hashable {
    public var id: UUID
    public var model: ModelDescriptor
    public var input: AIInput
    public var parameters: GenerationParameters

    public init(
        id: UUID = UUID(),
        model: ModelDescriptor,
        input: AIInput,
        parameters: GenerationParameters = GenerationParameters()
    ) {
        self.id = id
        self.model = model
        self.input = input
        self.parameters = parameters
    }
}
