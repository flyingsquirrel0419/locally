import XCTest
@testable import LocallyHF
import LocallyCore

final class RepoIDTests: XCTestCase {
    func testParsesValidIDs() throws {
        let id = try RepoID(parsing: "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
        XCTAssertEqual(id.owner, "mlx-community")
        XCTAssertEqual(id.name, "Qwen2.5-0.5B-Instruct-4bit")
        XCTAssertEqual(id.description, "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
        XCTAssertEqual(id.webURL.absoluteString,
                       "https://huggingface.co/mlx-community/Qwen2.5-0.5B-Instruct-4bit")
    }

    func testTrimsWhitespace() throws {
        let id = try RepoID(parsing: "  org/name \n")
        XCTAssertEqual(id.owner, "org")
        XCTAssertEqual(id.name, "name")
    }

    func testRejectsInvalidIDs() {
        let bad = ["", "org", "org/", "/name", "a/b/c", "-org/name",
                   "org name/x", "org/../x", "org//name"]
        for raw in bad {
            XCTAssertThrowsError(try RepoID(parsing: raw), raw) { error in
                guard case LocallyError.invalidRepoID = error else {
                    return XCTFail("wrong error for \(raw): \(error)")
                }
            }
        }
    }

    func testCodableRoundTrip() throws {
        let id = try RepoID(parsing: "org/name")
        let data = try JSONEncoder().encode(id)
        XCTAssertEqual(try JSONDecoder().decode(RepoID.self, from: data), id)
    }
}
