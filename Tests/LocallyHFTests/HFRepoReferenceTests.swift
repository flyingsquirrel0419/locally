import XCTest
@testable import LocallyHF
import LocallyCore

final class HFRepoReferenceTests: XCTestCase {
    func testBareRepoID() throws {
        let ref = try HFRepoReference(parsing: "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
        XCTAssertEqual(ref.repoID.description, "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
        XCTAssertNil(ref.revision)
        XCTAssertNil(ref.filePath)
    }

    func testFullURL() throws {
        let ref = try HFRepoReference(parsing: "https://huggingface.co/org/name")
        XCTAssertEqual(ref.repoID.description, "org/name")
        XCTAssertNil(ref.revision)
    }

    func testHFShortHost() throws {
        let ref = try HFRepoReference(parsing: "https://hf.co/org/name")
        XCTAssertEqual(ref.repoID.description, "org/name")
    }

    func testTreeRevision() throws {
        let ref = try HFRepoReference(parsing: "https://huggingface.co/org/name/tree/v1.0")
        XCTAssertEqual(ref.revision, "v1.0")
        XCTAssertNil(ref.filePath)
    }

    func testBlobPath() throws {
        let ref = try HFRepoReference(
            parsing: "https://huggingface.co/org/name/blob/main/sub/dir/file.gguf")
        XCTAssertEqual(ref.revision, "main")
        XCTAssertEqual(ref.filePath, "sub/dir/file.gguf")
    }

    func testResolvePath() throws {
        let ref = try HFRepoReference(
            parsing: "https://huggingface.co/org/name/resolve/main/model.safetensors")
        XCTAssertEqual(ref.revision, "main")
        XCTAssertEqual(ref.filePath, "model.safetensors")
    }

    func testTrailingSlashAndQueryFragment() throws {
        let ref = try HFRepoReference(parsing: "https://huggingface.co/org/name/?tab=readme#files")
        XCTAssertEqual(ref.repoID.description, "org/name")
        let ref2 = try HFRepoReference(parsing: "https://huggingface.co/org/name/tree/main/")
        XCTAssertEqual(ref2.revision, "main")
    }

    func testRejectsOtherHosts() {
        for raw in ["https://example.com/org/name", "http://huggingface.co/org/name"] {
            XCTAssertThrowsError(try HFRepoReference(parsing: raw), raw)
        }
    }

    func testRejectsSpacesAndTraversal() {
        XCTAssertThrowsError(try HFRepoReference(parsing: "org name/repo"))
        XCTAssertThrowsError(
            try HFRepoReference(parsing: "https://huggingface.co/org/name/blob/main/../secret"))
    }

    func testRejectsDatasetsAndSpacesWithClearError() {
        for raw in ["https://huggingface.co/datasets/org/name",
                    "https://huggingface.co/spaces/org/name"] {
            XCTAssertThrowsError(try HFRepoReference(parsing: raw)) { error in
                guard let err = error as? LocallyError else {
                    return XCTFail("wrong type")
                }
                XCTAssertTrue(err.userMessage.contains("model repositories"),
                              "unexpected message: \(err.userMessage)")
            }
        }
    }
}
