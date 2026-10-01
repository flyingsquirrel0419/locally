import Foundation
import LocallyCore

/// Hugging Face REST client. Read-only, HTTPS-only, sends the Authorization
/// header only when a token is configured. The token is never logged.
public actor HFClient {
    public static let defaultAPIBase = URL(string: "https://huggingface.co")!

    private let transport: any HTTPTransport
    private let tokenStore: any TokenStore
    private let apiBase: URL

    public init(transport: any HTTPTransport = URLSessionTransport(),
                tokenStore: any TokenStore = InMemoryTokenStore(),
                apiBase: URL = HFClient.defaultAPIBase) {
        self.transport = transport
        self.tokenStore = tokenStore
        self.apiBase = apiBase
    }

    /// Verify the configured token via /api/whoami-v2. Returns the username.
    public func verifyToken() async throws -> String {
        guard let token = try tokenStore.readToken(), !token.isEmpty else {
            throw LocallyError.network(
                userMessage: "Add a Hugging Face token first.",
                technicalDetail: "whoami-v2 called without a token"
            )
        }
        let response = try await get(path: "/api/whoami-v2")
        _ = token
        struct WhoAmI: Decodable { let name: String }
        do {
            return try JSONDecoder().decode(WhoAmI.self, from: response.body).name
        } catch {
            throw LocallyError.network(
                userMessage: "Couldn't read the Hugging Face account response.",
                technicalDetail: "whoami-v2 decode failed: \(error)"
            )
        }
    }

    /// File listing and repo metadata via /api/models/{repo}?blobs=true.
    public func repoInfo(_ repoID: RepoID, revision: String? = nil) async throws -> HFRepoInfo {
        var path = "/api/models/\(repoID)"
        if let revision {
            path += "/revision/\(Self.escape(revision))"
        }
        path += "?blobs=true"
        let response = try await get(path: path)
        do {
            return try JSONDecoder().decode(HFRepoInfo.self, from: response.body)
        } catch {
            throw LocallyError.network(
                userMessage: "Couldn't read the model information from Hugging Face.",
                technicalDetail: "repo info decode failed for \(repoID): \(error)"
            )
        }
    }

    /// Fetch a small text/JSON file (config.json, README.md, …) capped at `maxBytes`.
    public func fetchSmallFile(_ repoID: RepoID, revision: String?, path: String,
                               maxBytes: Int = 4 * 1024 * 1024) async throws -> Data {
        guard !path.contains(".."), !path.hasPrefix("/") else {
            throw LocallyError.pathTraversal(technicalDetail: "Unsafe remote path: \(path)")
        }
        let response = try await get(
            path: "/\(repoID)/resolve/\(Self.escape(revision ?? "main"))/\(Self.escapePath(path))",
            extraHeaders: ["Range": "bytes=0-\(maxBytes - 1)"]
        )
        // A full 200 response may exceed the cap; a 206 honors the Range.
        guard response.body.count <= maxBytes else {
            throw LocallyError.network(
                userMessage: "That file is too large to inspect.",
                technicalDetail: "\(path) exceeded \(maxBytes) bytes cap"
            )
        }
        return response.body
    }

    /// Read the first `length` bytes of a remote file via HTTP Range.
    public func fetchRange(_ repoID: RepoID, revision: String?, path: String,
                           offset: Int64 = 0, length: Int64) async throws -> Data {
        guard !path.contains(".."), !path.hasPrefix("/") else {
            throw LocallyError.pathTraversal(technicalDetail: "Unsafe remote path: \(path)")
        }
        let response = try await get(
            path: "/\(repoID)/resolve/\(Self.escape(revision ?? "main"))/\(Self.escapePath(path))",
            extraHeaders: ["Range": "bytes=\(offset)-\(offset + length - 1)"]
        )
        return response.body
    }

    // MARK: - Internals

    private func get(path: String, extraHeaders: [String: String] = [:]) async throws -> HTTPResponse {
        // Exact host or true subdomain only: "evilhuggingface.co" must fail.
        guard let url = URL(string: path, relativeTo: apiBase)?.absoluteURL,
              url.scheme == "https", let host = url.host,
              RedirectPolicy.isAllowedHFHost(host) || apiBase != Self.defaultAPIBase else {
            throw LocallyError.network(
                userMessage: "Refused to contact a non-Hugging Face server.",
                technicalDetail: "URL validation failed for path \(path)"
            )
        }
        var headers = extraHeaders
        if let token = try tokenStore.readToken(), !token.isEmpty {
            headers["Authorization"] = "Bearer \(token)"
        }
        let response = try await transport.get(url: url, headers: headers)
        return try Self.validate(response, path: path)
    }

    static func validate(_ response: HTTPResponse, path: String) throws -> HTTPResponse {
        switch response.statusCode {
        case 200, 206:
            return response
        case 401, 403:
            throw LocallyError.network(
                userMessage: "This repository is private or gated. Add a Hugging Face token with access in Settings.",
                technicalDetail: "HTTP \(response.statusCode) for \(path)"
            )
        case 404:
            throw LocallyError.modelNotFound(
                userMessage: "Couldn't find that model on Hugging Face. Check the name or link.",
                technicalDetail: "HTTP 404 for \(path)"
            )
        case 429:
            throw LocallyError.network(
                userMessage: "Hugging Face is rate-limiting requests. Try again in a minute.",
                technicalDetail: "HTTP 429 for \(path)"
            )
        default:
            throw LocallyError.network(
                userMessage: "Hugging Face returned an unexpected error (\(response.statusCode)).",
                technicalDetail: "HTTP \(response.statusCode) for \(path)"
            )
        }
    }

    static func map(urlError error: URLError) -> LocallyError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return .network(
                userMessage: "You're offline. Connect to the internet and try again.",
                technicalDetail: "URLError \(error.code.rawValue)"
            )
        case .timedOut:
            return .network(
                userMessage: "The request timed out. Try again.",
                technicalDetail: "URLError timedOut"
            )
        case .cancelled:
            return .cancelled
        default:
            return .network(
                userMessage: "A network error occurred. Try again.",
                technicalDetail: "URLError \(error.code.rawValue)"
            )
        }
    }

    static func escape(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? segment
    }

    private static func escapePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { escape(String($0)) }
            .joined(separator: "/")
    }
}

/// /api/models/{repo} response (subset).
public struct HFRepoInfo: Decodable, Sendable {
    public var id: String
    public var author: String?
    public var sha: String?
    public var lastModified: String?
    public var isPrivate: Bool?
    public var gated: GatedFlag?
    public var pipelineTag: String?
    public var libraryName: String?
    public var tags: [String]?
    public var siblings: [HFSibling]?
    public var cardData: [String: JSONValue]?

    public enum GatedFlag: Decodable, Sendable {
        case bool(Bool)
        case text(String)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let b = try? container.decode(Bool.self) { self = .bool(b) }
            else if let s = try? container.decode(String.self) { self = .text(s) }
            else { self = .bool(false) }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, author, sha, lastModified
        case isPrivate = "private"
        case gated
        case pipelineTag = "pipeline_tag"
        case libraryName = "library_name"
        case tags, siblings, cardData
    }
}

public struct HFSibling: Decodable, Sendable {
    public var rfilename: String
    public var size: Int64?
    public var lfs: LFSInfo?

    public struct LFSInfo: Decodable, Sendable {
        public var size: Int64?
        public var sha256: String?
    }
}

/// Minimal JSON value for decoding heterogeneous card data.
public enum JSONValue: Decodable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let n = try? container.decode(Double.self) { self = .number(n) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let a = try? container.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? container.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .null }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var stringArray: [String]? {
        if case .array(let a) = self { return a.compactMap(\.stringValue) }
        return nil
    }
}
