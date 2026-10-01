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

/// Strips Authorization when a redirect crosses to a host the token must
/// not reach, and refuses non-HTTPS redirects outright.
final class RedirectSanitizingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(RedirectPolicy.sanitize(request: request,
                                                  original: task.originalRequest ?? request))
    }
}

/// URLSession-based transport used by the app. Redirects pass through
/// `RedirectPolicy`, so the HF token never crosses to a foreign host even
/// when /resolve/ bounces to a CDN.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            self.session = URLSession(configuration: .default,
                                      delegate: RedirectSanitizingDelegate(),
                                      delegateQueue: nil)
        }
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
