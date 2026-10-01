import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LocallyCore

/// A raw HTTP response. Transport-agnostic so tests can mock it.
public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// Header lookup, case-insensitive per RFC 9110.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }
}

/// Injectable HTTP layer for HFClient. Only HTTPS GET requests are issued.
public protocol HTTPTransport: Sendable {
    func get(url: URL, headers: [String: String]) async throws -> HTTPResponse
}

/// URLSession-based transport used by the app.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func get(url: URL, headers: [String: String]) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw HFClient.map(urlError: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LocallyError.network(
                userMessage: "The server returned an unexpected response.",
                technicalDetail: "Non-HTTP response for \(url.host ?? "?")"
            )
        }
        var headerMap: [String: String] = [:]
        for case let (name as String, value as String) in http.allHeaderFields {
            headerMap[name] = value
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headerMap, body: data)
    }
}
