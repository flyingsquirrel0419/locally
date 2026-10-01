import XCTest
@testable import LocallyDevice

final class ResourcePolicyTests: XCTestCase {
    private let policy = ResourcePolicy()

    func testIdleNominalDoesNothing() {
        let actions = policy.decide(thermal: .nominal, lowPower: false,
                                    memoryPressure: .normal, activity: .idle)
        XCTAssertTrue(actions.isEmpty)
    }

    func testMemoryWarningStopsGenerationAndFreesCaches() {
        let actions = policy.decide(thermal: .nominal, lowPower: false,
                                    memoryPressure: .warning, activity: .textGeneration)
        XCTAssertTrue(actions.contains {
            if case .stopGeneration = $0 { return true }; return false
        })
        XCTAssertTrue(actions.contains {
            if case .unloadIdleModel = $0 { return true }; return false
        })
        XCTAssertTrue(actions.contains(.clearMediaCaches))
        XCTAssertTrue(actions.contains(.clearAcceleratorCaches))
    }

    func testMemoryWarningWhenIdleOnlyFreesResources() {
        let actions = policy.decide(thermal: .nominal, lowPower: false,
                                    memoryPressure: .warning, activity: .idle)
        XCTAssertFalse(actions.contains {
            if case .stopGeneration = $0 { return true }; return false
        })
        XCTAssertTrue(actions.contains {
            if case .unloadIdleModel = $0 { return true }; return false
        })
        XCTAssertTrue(actions.contains(.clearMediaCaches))
    }

    func testMemoryWarningDoesNotInterruptDownloads() {
        let actions = policy.decide(thermal: .nominal, lowPower: false,
                                    memoryPressure: .warning, activity: .downloading)
        XCTAssertFalse(actions.contains {
            if case .stopGeneration = $0 { return true }; return false
        })
    }

    func testCriticalThermalStopsAndRefusesHeavyInference() {
        let actions = policy.decide(thermal: .critical, lowPower: false,
                                    memoryPressure: .normal, activity: .imageGeneration)
        XCTAssertTrue(actions.contains {
            if case .stopGeneration = $0 { return true }; return false
        })
        XCTAssertTrue(actions.contains {
            if case .refuseHeavyInference = $0 { return true }; return false
        })
    }

    func testCriticalThermalWhileIdleStillRefuses() {
        let actions = policy.decide(thermal: .critical, lowPower: false,
                                    memoryPressure: .normal, activity: .idle)
        XCTAssertTrue(actions.contains {
            if case .refuseHeavyInference = $0 { return true }; return false
        })
        XCTAssertFalse(actions.contains {
            if case .stopGeneration = $0 { return true }; return false
        })
    }

    func testSeriousThermalThrottlesTextGeneration() {
        let actions = policy.decide(thermal: .serious, lowPower: false,
                                    memoryPressure: .normal, activity: .textGeneration)
        XCTAssertTrue(actions.contains {
            if case .throttleGeneration = $0 { return true }; return false
        })
        XCTAssertTrue(actions.contains {
            if case .reduceVideoFrameBudget = $0 { return true }; return false
        })
    }

    func testSeriousThermalWarnsOnImageGeneration() {
        let actions = policy.decide(thermal: .serious, lowPower: false,
                                    memoryPressure: .normal, activity: .imageGeneration)
        XCTAssertTrue(actions.contains {
            if case .warnImageGeneration = $0 { return true }; return false
        })
        XCTAssertFalse(actions.contains {
            if case .throttleGeneration = $0 { return true }; return false
        })
    }

    func testFairThermalDoesNothing() {
        let actions = policy.decide(thermal: .fair, lowPower: false,
                                    memoryPressure: .normal, activity: .textGeneration)
        XCTAssertTrue(actions.isEmpty)
    }

    func testLowPowerAddsBannerOnly() {
        let actions = policy.decide(thermal: .nominal, lowPower: true,
                                    memoryPressure: .normal, activity: .idle)
        XCTAssertEqual(actions.count, 1)
        guard case .lowPowerBanner = actions[0] else {
            return XCTFail("expected lowPowerBanner, got \(actions[0])")
        }
    }

    func testCombinedPressureAccumulatesActions() {
        let actions = policy.decide(thermal: .critical, lowPower: true,
                                    memoryPressure: .warning, activity: .textGeneration)
        // stopGeneration appears once even though two conditions demand it.
        let stops = actions.filter {
            if case .stopGeneration = $0 { return true }; return false
        }
        XCTAssertEqual(stops.count, 1)
        XCTAssertTrue(actions.contains {
            if case .refuseHeavyInference = $0 { return true }; return false
        })
        XCTAssertTrue(actions.contains {
            if case .lowPowerBanner = $0 { return true }; return false
        })
    }

    func testGateRefusesOnCritical() {
        let gate = policy.gate(thermal: .critical, memoryPressure: .normal)
        XCTAssertFalse(gate.allowed)
        XCTAssertNotNil(gate.reason)
    }

    func testGateRefusesOnMemoryWarning() {
        let gate = policy.gate(thermal: .nominal, memoryPressure: .warning)
        XCTAssertFalse(gate.allowed)
        XCTAssertNotNil(gate.reason)
    }

    func testGateAllowsNominal() {
        let gate = policy.gate(thermal: .serious, memoryPressure: .normal)
        XCTAssertTrue(gate.allowed)
        XCTAssertNil(gate.reason)
    }

    func testThrottleDelayIsPositiveAndSmall() {
        XCTAssertGreaterThan(policy.throttleInterTokenDelayNanoseconds, 0)
        XCTAssertLessThanOrEqual(policy.throttleInterTokenDelayNanoseconds, 100_000_000)
    }

    func testHeavyInferenceClassification() {
        XCTAssertTrue(ResourcePolicy.Activity.textGeneration.isHeavyInference)
        XCTAssertTrue(ResourcePolicy.Activity.imageGeneration.isHeavyInference)
        XCTAssertTrue(ResourcePolicy.Activity.visionInference.isHeavyInference)
        XCTAssertTrue(ResourcePolicy.Activity.videoAnalysis.isHeavyInference)
        XCTAssertFalse(ResourcePolicy.Activity.idle.isHeavyInference)
        XCTAssertFalse(ResourcePolicy.Activity.downloading.isHeavyInference)
    }
}
