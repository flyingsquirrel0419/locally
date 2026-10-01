import XCTest
@testable import LocallyStorage
import LocallyCore

final class PathSanitizerTests: XCTestCase {
    func testAcceptsNormalPaths() throws {
        XCTAssertEqual(try PathSanitizer.sanitizeRepoPath("weights/model.safetensors"),
                       "weights/model.safetensors")
        XCTAssertEqual(try PathSanitizer.sanitizeRepoPath("config.json"), "config.json")
    }

    func testRejectsTraversalAndUnsafe() {
        let bad = ["../secret", "a/../../b", "/abs/path", "a//b", "", "a/./b",
                   "a\\b", "x\0y", ".."]
        for path in bad {
            XCTAssertThrowsError(try PathSanitizer.sanitizeRepoPath(path), path) { error in
                guard case LocallyError.pathTraversal = error else {
                    return XCTFail("wrong error for \(path): \(error)")
                }
            }
        }
    }

    func testResolveUnderStaysInsideBase() throws {
        let base = URL(fileURLWithPath: "/tmp/locally-test-base")
        let url = try PathSanitizer.resolveUnder(base: base, relative: "a/b.bin")
        XCTAssertEqual(url.path, "/tmp/locally-test-base/a/b.bin")
        XCTAssertThrowsError(try PathSanitizer.resolveUnder(base: base, relative: "../escape"))
    }
}
