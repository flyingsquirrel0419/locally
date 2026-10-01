import Foundation

/// A single file of a remote model repository.
public struct RemoteModelFile: Codable, Sendable, Hashable {
    /// Repository-relative path. Must not contain ".." or be absolute.
    public var path: String
    public var size: Int64
    public var sha256: String?

    public init(path: String, size: Int64, sha256: String? = nil) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

/// Everything the app knows about a model before or after download.
public struct ModelDescriptor: Codable, Sendable, Hashable {
    /// Hugging Face style "org/name" identifier.
    public var repoID: String
    public var name: String
    public var architecture: String?
    public var modality: ModelModality
    public var parameterCount: Int64?
    public var quantization: Quantization?
    public var formats: [ModelFormat]
    /// Sum of `requiredFiles` sizes in bytes, when known.
    public var totalDownloadSize: Int64?
    public var requiredFiles: [RemoteModelFile]
    public var estimatedWeightMemory: Int64?
    public var estimatedRuntimeMemory: Int64?
    public var supportedRuntimes: [RuntimeKind]
    public var contextLength: Int?
    /// Free-form extra values from repo metadata (e.g. license, pipeline tag).
    public var metadata: [String: String]

    public init(
        repoID: String,
        name: String,
        architecture: String? = nil,
        modality: ModelModality = .unknown,
        parameterCount: Int64? = nil,
        quantization: Quantization? = nil,
        formats: [ModelFormat] = [],
        totalDownloadSize: Int64? = nil,
        requiredFiles: [RemoteModelFile] = [],
        estimatedWeightMemory: Int64? = nil,
        estimatedRuntimeMemory: Int64? = nil,
        supportedRuntimes: [RuntimeKind] = [],
        contextLength: Int? = nil,
        metadata: [String: String] = [:]
    ) {
        self.repoID = repoID
        self.name = name
        self.architecture = architecture
        self.modality = modality
        self.parameterCount = parameterCount
        self.quantization = quantization
        self.formats = formats
        self.totalDownloadSize = totalDownloadSize
        self.requiredFiles = requiredFiles
        self.estimatedWeightMemory = estimatedWeightMemory
        self.estimatedRuntimeMemory = estimatedRuntimeMemory
        self.supportedRuntimes = supportedRuntimes
        self.contextLength = contextLength
        self.metadata = metadata
    }
}
