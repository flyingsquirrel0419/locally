import Foundation

/// The primary task class a model performs.
public enum ModelModality: String, Codable, Sendable, Hashable, CaseIterable {
    case text
    case visionLanguage
    case imageUnderstanding
    case imageGeneration
    case speechRecognition
    case speechSynthesis
    case audio
    case embedding
    case reranker
    case decision
    case videoUnderstanding
    case videoGeneration
    case unknown
}

/// A serialized weight / artifact format for a model.
public enum ModelFormat: String, Codable, Sendable, Hashable, CaseIterable {
    case mlx
    case gguf
    case safetensors
    case coreml
    case onnx
    case other
}

/// On-device execution stack a model can run on.
public enum RuntimeKind: String, Codable, Sendable, Hashable, CaseIterable {
    case mlx
    case gguf
    case coreml
    case decision
    case vision
    case diffusion
    case audio
    case video
}
