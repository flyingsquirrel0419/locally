import XCTest
@testable import LocallyCompatibility
import LocallyCore
import LocallyDevice

final class CompatibilityRatingTests: XCTestCase {
    func testRatioBands() {
        let budget: UInt64 = 1_000_000_000
        XCTAssertEqual(CompatibilityRule.rate(requiredBytes: 400_000_000, budgetBytes: budget), .excellent)
        XCTAssertEqual(CompatibilityRule.rate(requiredBytes: 700_000_000, budgetBytes: budget), .good)
        XCTAssertEqual(CompatibilityRule.rate(requiredBytes: 900_000_000, budgetBytes: budget), .marginal)
        XCTAssertEqual(CompatibilityRule.rate(requiredBytes: 1_050_000_000, budgetBytes: budget), .unlikely)
        XCTAssertEqual(CompatibilityRule.rate(requiredBytes: 2_000_000_000, budgetBytes: budget), .incompatible)
    }

    func testUnknownForZeroInputs() {
        XCTAssertEqual(CompatibilityRule.rate(requiredBytes: 0, budgetBytes: 100), .unknown)
        XCTAssertEqual(CompatibilityRule.rate(requiredBytes: 100, budgetBytes: 0), .unknown)
    }

    func testDescriptorRatingUsesRuntimeEstimate() {
        var descriptor = ModelDescriptor(repoID: "org/m", name: "m")
        descriptor.estimatedRuntimeMemory = 400_000_000
        descriptor.estimatedWeightMemory = 200_000_000
        let profile = DeviceProfile(
            modelIdentifier: "test",
            osVersion: "1.0",
            physicalMemory: 8_000_000_000,
            availableMemoryEstimate: 4_000_000_000,
            metalAvailable: false,
            recommendedMaxWorkingSet: 1_000_000_000,
            processorCount: 8,
            activeProcessorCount: 8
        )
        XCTAssertEqual(CompatibilityRule.rate(descriptor: descriptor, profile: profile), .excellent)
    }

    func testDescriptorRatingUnknownWithoutEstimates() {
        let descriptor = ModelDescriptor(repoID: "org/m", name: "m")
        let profile = DeviceProfile(
            modelIdentifier: "test",
            osVersion: "1.0",
            physicalMemory: 8_000_000_000,
            availableMemoryEstimate: 4_000_000_000,
            metalAvailable: false,
            processorCount: 8,
            activeProcessorCount: 8
        )
        XCTAssertEqual(CompatibilityRule.rate(descriptor: descriptor, profile: profile), .unknown)
    }
}
