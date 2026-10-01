import XCTest
@testable import LocallyHF
import LocallyCore

final class HFClientTests: XCTestCase {
    private func makeClient(transport: MockTransport, token: String? = nil) -> HFClient {
        HFClient(transport: transport, tokenStore: InMemoryTokenStore(token: token))
    }

    func testWhoAmIReturnsUsername() async throws {
        let transport = MockTransport()
        transport.stubJSON("/api/whoami-v2", json: #"{"name": "wickeddev", "type": "user"}"#)
        let client = makeClient(transport: transport, token: "hf_x")
        let name = try await client.verifyToken()
        XCTAssertEqual(name, "wickeddev")
    }

    func testAuthorizationHeaderOnlyWithToken() async throws {
        let transport = MockTransport()
        transport.stubJSON("/api/whoami-v2", json: #"{"name": "u"}"#)

        let withToken = makeClient(transport: transport, token: "hf_x")
        _ = try await withToken.verifyToken()
        XCTAssertEqual(transport.requests.last?.headers["Authorization"], "Bearer hf_x")

        let withoutToken = HFClient(transport: transport, tokenStore: InMemoryTokenStore())
        do { _ = try await withoutToken.verifyToken() } catch {}
        // No request should even be attempted without a token.
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testWhoAmIWithoutTokenThrows() async {
        let client = HFClient(transport: MockTransport(), tokenStore: InMemoryTokenStore())
        do {
            _ = try await client.verifyToken()
            XCTFail("expected error")
        } catch let error as LocallyError {
            guard case .network = error else { return XCTFail("wrong case: \(error)") }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testRepoInfoDecodesSiblings() async throws {
        let transport = MockTransport()
        let json = try String(decoding: Fixtures.data("mlx-qwen/repo_info.json"), as: UTF8.self)
        transport.stubJSON("/api/models/", json: json)
        let client = makeClient(transport: transport)
        let info = try await client.repoInfo(RepoID(parsing: "mlx-community/Qwen2.5-0.5B-Instruct-4bit"))
        XCTAssertEqual(info.pipelineTag, "text-generation")
        XCTAssertEqual(info.libraryName, "mlx")
        let model = info.siblings?.first { $0.rfilename == "model.safetensors" }
        XCTAssertEqual(model?.size, 371_000_000)
        XCTAssertEqual(model?.lfs?.sha256?.count, 64)
        // Request includes blobs=true
        XCTAssertTrue(transport.requests.last?.url.absoluteString.contains("blobs=true") == true)
    }

    func testRepoInfoRevisionPath() async throws {
        let transport = MockTransport()
        transport.stubJSON("/api/models/", json: #"{"id": "org/name"}"#)
        let client = makeClient(transport: transport)
        _ = try await client.repoInfo(RepoID(parsing: "org/name"), revision: "v2")
        XCTAssertTrue(transport.requests.last?.url.path.contains("/revision/v2") == true)
    }

    func testErrorMapping() async {
        let cases: [(Int, String)] = [
            (401, "private or gated"),
            (403, "private or gated"),
            (404, "Couldn't find"),
            (429, "rate-limiting"),
        ]
        for (status, messagePart) in cases {
            let transport = MockTransport()
            transport.stubJSON("/api/whoami-v2", json: "{}", status: status)
            let client = makeClient(transport: transport, token: "hf_x")
            do {
                _ = try await client.verifyToken()
                XCTFail("expected error for \(status)")
            } catch let error as LocallyError {
                XCTAssertTrue(error.userMessage.contains(messagePart),
                              "status \(status) message: \(error.userMessage)")
                XCTAssertFalse(error.userMessage.contains("hf_x"))
                XCTAssertFalse(error.technicalDetail.contains("hf_x"))
            } catch {
                XCTFail("unexpected error type: \(error)")
            }
        }
    }

    func testSmallFileCap() async throws {
        let transport = MockTransport()
        transport.stubData("/resolve/", data: Data(repeating: 0x41, count: 5_000_000))
        let client = makeClient(transport: transport)
        do {
            _ = try await client.fetchSmallFile(RepoID(parsing: "org/name"), revision: nil,
                                                path: "config.json", maxBytes: 4 * 1024 * 1024)
            XCTFail("expected cap error")
        } catch let error as LocallyError {
            guard case .network = error else { return XCTFail("wrong case: \(error)") }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testFetchRangeSendsRangeHeader() async throws {
        let transport = MockTransport()
        transport.stubData("/resolve/", data: Data(repeating: 0x00, count: 24))
        let client = makeClient(transport: transport)
        _ = try await client.fetchRange(RepoID(parsing: "org/name"), revision: "main",
                                        path: "model.gguf", length: 24)
        XCTAssertEqual(transport.requests.last?.headers["Range"], "bytes=0-23")
    }

    func testPathTraversalRejected() async {
        let client = makeClient(transport: MockTransport())
        for bad in ["../secret", "/etc/passwd"] {
            do {
                _ = try await client.fetchSmallFile(RepoID(parsing: "org/name"),
                                                    revision: nil, path: bad)
                XCTFail("expected traversal rejection for \(bad)")
            } catch let error as LocallyError {
                guard case .pathTraversal = error else {
                    return XCTFail("wrong case: \(error)")
                }
            } catch {
                XCTFail("unexpected error type: \(error)")
            }
        }
    }
}
