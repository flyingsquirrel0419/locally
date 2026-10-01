import Foundation

/// Unified error type. `userMessage` is safe to show in the UI;
/// `technicalDetail` is for logs and diagnostics only.
public enum LocallyError: Error, Sendable, Hashable {
    case network(userMessage: String, technicalDetail: String)
    case downloadFailed(userMessage: String, technicalDetail: String)
    case invalidRepoID(userMessage: String, technicalDetail: String)
    case modelNotFound(userMessage: String, technicalDetail: String)
    case unsupportedModality(userMessage: String, technicalDetail: String)
    case unsupportedFormat(userMessage: String, technicalDetail: String)
    case insufficientStorage(userMessage: String, technicalDetail: String)
    case insufficientMemory(userMessage: String, technicalDetail: String)
    case runtimeUnavailable(userMessage: String, technicalDetail: String)
    case inferenceFailed(userMessage: String, technicalDetail: String)
    case cancelled
    case storageCorrupted(userMessage: String, technicalDetail: String)
    case pathTraversal(technicalDetail: String)
    case unknown(userMessage: String, technicalDetail: String)

    public var userMessage: String {
        switch self {
        case .network(let m, _), .downloadFailed(let m, _),
             .invalidRepoID(let m, _), .modelNotFound(let m, _),
             .unsupportedModality(let m, _), .unsupportedFormat(let m, _),
             .insufficientStorage(let m, _), .insufficientMemory(let m, _),
             .runtimeUnavailable(let m, _), .inferenceFailed(let m, _),
             .storageCorrupted(let m, _), .unknown(let m, _):
            return m
        case .cancelled:
            return "The operation was cancelled."
        case .pathTraversal:
            return "The model repository contains an unsafe file path."
        }
    }

    public var technicalDetail: String {
        switch self {
        case .network(_, let d), .downloadFailed(_, let d),
             .invalidRepoID(_, let d), .modelNotFound(_, let d),
             .unsupportedModality(_, let d), .unsupportedFormat(_, let d),
             .insufficientStorage(_, let d), .insufficientMemory(_, let d),
             .runtimeUnavailable(_, let d), .inferenceFailed(_, let d),
             .storageCorrupted(_, let d), .pathTraversal(let d),
             .unknown(_, let d):
            return d
        case .cancelled:
            return "cancelled"
        }
    }
}

extension LocallyError: LocalizedError {
    public var errorDescription: String? { userMessage }
}
