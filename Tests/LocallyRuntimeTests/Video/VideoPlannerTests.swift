import XCTest
@testable import LocallyRuntime
import LocallyCore

final class VideoSamplingPlannerTests: XCTestCase {
    typealias Planner = VideoSamplingPlanner
    typealias Context = VideoSamplingPlanner.Context

    // MARK: - Adaptive frame count

    func testAdaptiveFrameCountByDuration() {
        XCTAssertEqual(Planner.adaptiveFrameCount(duration: 3), 8)
        XCTAssertEqual(Planner.adaptiveFrameCount(duration: 14.9), 8)
        XCTAssertEqual(Planner.adaptiveFrameCount(duration: 15), 16)
        XCTAssertEqual(Planner.adaptiveFrameCount(duration: 119), 16)
        XCTAssertEqual(Planner.adaptiveFrameCount(duration: 120), 32)
        XCTAssertEqual(Planner.adaptiveFrameCount(duration: 3600), 32)
    }

    func testPressureHalvesAndFloorsAtFour() {
        XCTAssertEqual(Planner.pressuredFrameCount(base: 16, thermal: .serious,
                                                   lowPowerMode: false), 8)
        XCTAssertEqual(Planner.pressuredFrameCount(base: 32, thermal: .nominal,
                                                   lowPowerMode: true), 16)
        XCTAssertEqual(Planner.pressuredFrameCount(base: 8, thermal: .serious,
                                                   lowPowerMode: true), 4)
        XCTAssertEqual(Planner.pressuredFrameCount(base: 4, thermal: .serious,
                                                   lowPowerMode: true), 4)
    }

    // MARK: - Plan

    func testPlanRefusesOnCriticalThermal() {
        let planner = Planner()
        let context = Context(duration: 60, thermal: .critical)
        XCTAssertThrowsError(try planner.plan(context)) { error in
            guard case Planner.PlanError.refusedThermal = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testPlanRejectsNonPositiveDuration() {
        let planner = Planner()
        XCTAssertThrowsError(try planner.plan(Context(duration: 0)))
        XCTAssertThrowsError(try planner.plan(Context(duration: -5)))
        XCTAssertThrowsError(try planner.plan(Context(duration: .nan)))
    }

    func testUniformTimestampsAreSegmentMidpoints() {
        let ts = Planner.uniformTimestamps(duration: 100, count: 10)
        XCTAssertEqual(ts.count, 10)
        XCTAssertEqual(ts.first!, 5, accuracy: 1e-9)
        XCTAssertEqual(ts.last!, 95, accuracy: 1e-9)
        // Evenly spaced and deterministic.
        XCTAssertEqual(ts, Planner.uniformTimestamps(duration: 100, count: 10))
        for pair in zip(ts, ts.dropFirst()) {
            XCTAssertEqual(pair.1 - pair.0, 10, accuracy: 1e-9)
        }
    }

    func testPlanBatchesRespectModelLimit() throws {
        let planner = Planner()
        let context = Context(duration: 200, memoryBudgetBytes: 512_000_000,
                              imagesPerRequest: 4)
        let plan = try planner.plan(context)
        XCTAssertEqual(plan.frameCount, 32)
        XCTAssertLessThanOrEqual(plan.batchSize, 4)
        let batches = plan.batches
        XCTAssertEqual(batches.flatMap { $0 }, plan.timestamps)
        for batch in batches { XCTAssertLessThanOrEqual(batch.count, plan.batchSize) }
    }

    func testBatchSizeFallsToOneUnderTightMemory() {
        let size = ImagePreprocessingPlanner.PixelSize(width: 1536, height: 1536)
        let batch = Planner.batchSize(imagesPerRequest: 4, frameTarget: size,
                                      memoryBudgetBytes: 1_000_000)
        XCTAssertEqual(batch, 1)
    }

    func testSingleImageModelGetsBatchesOfOne() throws {
        let planner = Planner()
        let context = Context(duration: 60, imagesPerRequest: 1)
        let plan = try planner.plan(context)
        XCTAssertEqual(plan.batchSize, 1)
        XCTAssertEqual(plan.batches.count, plan.frameCount)
    }

    func testUserOverrideWins() throws {
        let planner = Planner()
        let context = Context(duration: 10, requestedFrameCount: 32)
        let plan = try planner.plan(context)
        XCTAssertEqual(plan.frameCount, 32)
    }

    func testReasonMentionsPressureReduction() throws {
        let planner = Planner()
        let context = Context(duration: 60, thermal: .serious)
        let plan = try planner.plan(context)
        XCTAssertEqual(plan.frameCount, 8)
        XCTAssertTrue(plan.reason.contains("pressure"))
    }
}

final class VideoAggregationPlannerTests: XCTestCase {
    let planner = VideoAggregationPlanner()

    func testBatchPromptLabelsTimestamps() {
        let prompt = planner.batchPrompt(mode: .describe, question: nil,
                                         timestamps: [5.0, 15.0])
        XCTAssertTrue(prompt.contains("[t=5.0s]"))
        XCTAssertTrue(prompt.contains("[t=15.0s]"))
        XCTAssertTrue(prompt.contains("2 frames"))
    }

    func testQuestionModeEmbedsQuestion() {
        let prompt = planner.batchPrompt(mode: .question,
                                         question: "What color is the car?",
                                         timestamps: [1.0])
        XCTAssertTrue(prompt.contains("What color is the car?"))
    }

    func testAggregationPromptJoinsSegments() {
        let prompt = planner.aggregationPrompt(mode: .summarize, question: nil,
                                               batchAnswers: ["alpha", "beta"])
        XCTAssertTrue(prompt.contains("Segment 1:"))
        XCTAssertTrue(prompt.contains("alpha"))
        XCTAssertTrue(prompt.contains("Segment 2:"))
        XCTAssertTrue(prompt.contains("beta"))
        XCTAssertTrue(prompt.contains("2 segments"))
    }

    func testTimestampFormatting() {
        XCTAssertEqual(VideoAggregationPlanner.formatTimestamp(12.34), "[t=12.3s]")
        XCTAssertEqual(VideoAggregationPlanner.formatTimestamp(0), "[t=0.0s]")
    }

    // MARK: - Citation parsing

    func testParsesCitedTimestampsIntoRanges() {
        let ranges = VideoAggregationPlanner.citedRanges(
            in: "At [t=10.0s] the door opens; later at [t=50.5s] it closes.",
            duration: 60)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].start, 8.0, accuracy: 1e-9)
        XCTAssertEqual(ranges[0].end, 12.0, accuracy: 1e-9)
        XCTAssertEqual(ranges[1].start, 48.5, accuracy: 1e-9)
    }

    func testRangesClampedToDuration() {
        let ranges = VideoAggregationPlanner.citedRanges(
            in: "Start [t=1.0s] and end [t=59.5s]", duration: 60)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].start, 0)
        XCTAssertEqual(ranges[1].end, 60)
    }

    func testOutOfRangeCitationsDropped() {
        let ranges = VideoAggregationPlanner.citedRanges(
            in: "Beyond the end [t=500.0s]", duration: 60)
        XCTAssertTrue(ranges.isEmpty)
    }

    func testMalformedCitationsIgnored() {
        let text = "[t=abcs] [t=] [t=12.5x] and a real [t=3.0s]"
        let ranges = VideoAggregationPlanner.citedRanges(in: text, duration: 60)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].start, 1.0, accuracy: 1e-9)
    }

    func testDuplicateCitationsCollapsedAndSorted() {
        let ranges = VideoAggregationPlanner.citedRanges(
            in: "[t=20.0s] then [t=5.0s] then [t=20.0s] again", duration: 60)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertLessThan(ranges[0].start, ranges[1].start)
    }
}

final class VideoGenerationRuntimeTests: XCTestCase {
    private var model: ModelDescriptor {
        ModelDescriptor(repoID: "org/t2v", name: "t2v", modality: .videoGeneration)
    }

    func testReportsUnsupportedHonestly() async {
        let runtime = ExperimentalVideoGenerationRuntime()
        XCTAssertFalse(runtime.isSupported(on: DeviceCapabilities(
            physicalMemory: 8_000_000_000, metalAvailable: true,
            neuralEngineAvailable: true)))
        guard case .unsupported(let reason) = runtime.compatibility(
            with: model, on: DeviceCapabilities(physicalMemory: 1, metalAvailable: true,
                                                neuralEngineAvailable: true)) else {
            return XCTFail("expected unsupported")
        }
        XCTAssertTrue(reason.contains("experimental"))

        let request = AIRequest(model: model, input: .text("a cat"))
        let events = await TerminalEventInvariant.assertStream(runtime.run(request))
        XCTAssertEqual(events.count, 1)
        guard case .failed(let error) = events.first,
              case .unsupportedModality = error else {
            return XCTFail("expected failed(unsupportedModality), got \(events)")
        }
    }
}
