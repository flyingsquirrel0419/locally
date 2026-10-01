import Foundation
import LocallyCore

/// Parsed Hugging Face repo identifier "org/name" with strict validation.
/// Week 2 builds the full HF client on top of this.
public struct RepoID: Codable, Sendable, Hashable, CustomStringConvertible {
    public var owner: String
    public var name: String

    private static func isValidComponent(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 96,
              let first = s.first, first.isLetter || first.isNumber else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
    }

    public init(owner: String, name: String) throws {
        guard RepoID.isValidComponent(owner), RepoID.isValidComponent(name) else {
            throw LocallyError.invalidRepoID(
                userMessage: "That doesn't look like a valid model repository.",
                technicalDetail: "Invalid repo id: \(owner)/\(name)"
            )
        }
        self.owner = owner
        self.name = name
    }

    public init(parsing raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw LocallyError.invalidRepoID(
                userMessage: "That doesn't look like a valid model repository.",
                technicalDetail: "Invalid repo id: \(raw)"
            )
        }
        try self.init(owner: String(parts[0]), name: String(parts[1]))
    }

    public var description: String { "\(owner)/\(name)" }

    /// https://huggingface.co/<owner>/<name>
    public var webURL: URL {
        URL(string: "https://huggingface.co/\(owner)/\(name)")!
    }
}
