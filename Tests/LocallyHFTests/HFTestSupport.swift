import Foundation
@testable import LocallyHF
import LocallyCore

/// Mock HTTP transport scripted with responses per URL path suffix.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct RecordedRequest: Sendable {
        var url: URL
        var headers: [String: String]
    }

    private(set) var requests: [RecordedRequest] = []
    var responders: [(String) -> HTTPResponse?] = []

    func get(url: URL, headers: [String: String]) async throws -> HTTPResponse {
        requests.append(RecordedRequest(url: url, headers: headers))
        let path = url.path + (url.query.map { "?" + $0 } ?? "")
        for responder in responders {
            if let response = responder(path) { return response }
        }
        return HTTPResponse(statusCode: 404)
    }

    func stubJSON(_ pathSuffix: String, json: String, status: Int = 200) {
        responders.append { path in
            path.contains(pathSuffix)
                ? HTTPResponse(statusCode: status, body: Data(json.utf8))
                : nil
        }
    }

    func stubData(_ pathSuffix: String, data: Data, status: Int = 200) {
        responders.append { path in
            path.contains(pathSuffix) ? HTTPResponse(statusCode: status, body: data) : nil
        }
    }
}

/// Loads fixtures from Tests/Fixtures/HF, located relative to this source file.
enum Fixtures {
    static let base = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // LocallyHFTests
        .deletingLastPathComponent() // Tests
        .appendingPathComponent("Fixtures/HF")

    static func data(_ relative: String) throws -> Data {
        try Data(contentsOf: base.appendingPathComponent(relative))
    }

    static func repoInfo(_ directory: String) throws -> HFRepoInfo {
        try JSONDecoder().decode(HFRepoInfo.self, from: data("\(directory)/repo_info.json"))
    }

    static func config(_ directory: String, _ name: String = "config.json") throws -> ModelConfig? {
        let url = base.appendingPathComponent("\(directory)/\(name)")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try ModelConfig(data: Data(contentsOf: url))
    }

    static func readme(_ directory: String) throws -> CardFrontMatter? {
        let url = base.appendingPathComponent("\(directory)/README.md")
        guard FileManager.default.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return CardFrontMatter(markdown: text)
    }
}
