import XCTest
@testable import LocallyHF
import LocallyCore

final class TokenStoreTests: XCTestCase {
    func testInMemoryRoundTrip() throws {
        let store = InMemoryTokenStore()
        XCTAssertNil(try store.readToken())
        try store.saveToken("hf_testtoken123")
        XCTAssertEqual(try store.readToken(), "hf_testtoken123")
        try store.removeToken()
        XCTAssertNil(try store.readToken())
    }

    /// Tokens must never appear in any error surfaced by the app.
    func testErrorDescriptionsNeverContainToken() async throws {
        let token = "hf_secret_abc123def456"
        let store = InMemoryTokenStore(token: token)
        let transport = MockTransport()
        transport.responders.append { _ in
            HTTPResponse(statusCode: 401, body: Data("unauthorized".utf8))
        }
        let client = HFClient(transport: transport, tokenStore: store)
        do {
            _ = try await client.verifyToken()
            XCTFail("expected error")
        } catch {
            let description = String(describing: error)
            let localized = (error as? LocallyError)?.userMessage ?? ""
            let technical = (error as? LocallyError)?.technicalDetail ?? ""
            XCTAssertFalse(description.contains(token))
            XCTAssertFalse(localized.contains(token))
            XCTAssertFalse(technical.contains(token))
        }
    }
}
