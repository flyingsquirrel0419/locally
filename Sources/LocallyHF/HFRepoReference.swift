import Foundation
import LocallyCore

/// A parsed Hugging Face model repository reference: a validated `RepoID`
/// plus an optional revision (branch, tag, or commit) and file path,
/// extracted from user input such as "org/name", a huggingface.co URL,
/// or an hf.co short link.
public struct HFRepoReference: Sendable, Hashable {
    public var repoID: RepoID
    public var revision: String?
    public var filePath: String?

    public init(repoID: RepoID, revision: String? = nil, filePath: String? = nil) {
        self.repoID = repoID
        self.revision = revision
        self.filePath = filePath
    }

    private static let allowedHosts: Set<String> = ["huggingface.co", "www.huggingface.co", "hf.co"]

    /// Parse "org/name" or a Hugging Face URL into a reference.
    /// Accepts /tree/<rev>, /blob/<rev>/<path>, /resolve/<rev>/<path> suffixes.
    /// Rejects dataset/space URLs and any other host explicitly.
    public init(parsing raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else {
            throw Self.invalidInput(raw)
        }

        if trimmed.contains("://") || trimmed.lowercased().hasPrefix("huggingface.co")
            || trimmed.lowercased().hasPrefix("hf.co") {
            try self.init(parsingURL: trimmed)
        } else {
            self.init(repoID: try RepoID(parsing: trimmed))
        }
    }

    private init(parsingURL raw: String) throws {
        let withScheme: String
        if raw.contains("://") {
            withScheme = raw
        } else {
            withScheme = "https://" + raw
        }
        guard let components = URLComponents(string: withScheme),
              let host = components.host?.lowercased() else {
            throw Self.invalidInput(raw)
        }
        guard Self.allowedHosts.contains(host) else {
            throw LocallyError.invalidRepoID(
                userMessage: "Only Hugging Face links are supported here.",
                technicalDetail: "Unsupported host: \(host)"
            )
        }
        guard components.scheme?.lowercased() == "https" || components.scheme == nil else {
            throw LocallyError.invalidRepoID(
                userMessage: "Only HTTPS Hugging Face links are supported.",
                technicalDetail: "Unsupported scheme: \(components.scheme ?? "none")"
            )
        }

        var segments = components.path.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard segments.count >= 2 else {
            throw Self.invalidInput(raw)
        }
        if segments[0] == "datasets" || segments[0] == "spaces" {
            throw LocallyError.invalidRepoID(
                userMessage: "That's a \(segments[0] == "datasets" ? "dataset" : "Space") link — Locally only works with model repositories.",
                technicalDetail: "Non-model repo type in URL: \(raw)"
            )
        }
        let owner = segments[0]
        let name = segments[1]
        segments.removeFirst(2)

        var revision: String?
        var filePath: String?
        if let marker = segments.first {
            switch marker {
            case "tree":
                revision = segments.dropFirst().first
            case "blob", "resolve":
                if segments.count >= 2 {
                    revision = segments[1]
                    if segments.count > 2 {
                        filePath = segments.dropFirst(2).joined(separator: "/")
                    }
                }
            default:
                throw Self.invalidInput(raw)
            }
        }
        if let revision, revision.isEmpty { throw Self.invalidInput(raw) }
        if let filePath, (filePath.isEmpty || filePath.contains("..") || filePath.hasPrefix("/")) {
            throw LocallyError.pathTraversal(technicalDetail: "Unsafe path in URL: \(filePath)")
        }

        self.init(repoID: try RepoID(owner: owner, name: name),
                  revision: revision, filePath: filePath)
    }

    private static func invalidInput(_ raw: String) -> LocallyError {
        .invalidRepoID(
            userMessage: "That doesn't look like a valid model repository or Hugging Face link.",
            technicalDetail: "Unparseable repo reference: \(raw)"
        )
    }
}
