import XCTest
import LocallyCore
import LocallyHF

/// Smoke test proving the app test bundle links the package products and
/// their core value types work under the iOS test runner.
final class AppSmokeTests: XCTestCase {
    func testCoreTypesRoundTrip() throws {
        let descriptor = ModelDescriptor(repoID: "org/name", name: "name")
        XCTAssertEqual(descriptor.modality, .unknown)
        let data = try JSONEncoder().encode(descriptor)
        XCTAssertEqual(try JSONDecoder().decode(ModelDescriptor.self, from: data), descriptor)
    }

    func testHFReferenceParsingWorksInAppBundle() throws {
        let ref = try HFRepoReference(parsing: "https://huggingface.co/org/name/tree/main")
        XCTAssertEqual(ref.repoID.description, "org/name")
        XCTAssertEqual(ref.revision, "main")
    }
}
