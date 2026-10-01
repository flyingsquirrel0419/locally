import XCTest
@testable import LocallyRuntime

final class ImagePreprocessingPlannerTests: XCTestCase {
    typealias Planner = ImagePreprocessingPlanner
    typealias Config = ImagePreprocessingPlanner.ProcessorConfig
    typealias Size = ImagePreprocessingPlanner.PixelSize

    // MARK: - Config parsing

    func testParsesQwenVLStyleConfig() throws {
        let json = """
        {"patch_size": 14, "merge_size": 2, "min_pixels": 3136,
         "max_pixels": 12845056, "image_mean": [0.5, 0.5, 0.5]}
        """.data(using: .utf8)!
        let config = try XCTUnwrap(Config.parse(json: json))
        XCTAssertEqual(config.patchSize, 14)
        XCTAssertEqual(config.mergeSize, 2)
        XCTAssertEqual(config.minPixels, 3136)
        XCTAssertEqual(config.maxPixels, 12_845_056)
        XCTAssertNil(config.imageSize)
    }

    func testParsesNestedSigLIPSize() throws {
        let json = """
        {"size": {"shortest_edge": 384, "longest_edge": 768}}
        """.data(using: .utf8)!
        let config = try XCTUnwrap(Config.parse(json: json))
        XCTAssertEqual(config.shortestEdge, 384)
        XCTAssertEqual(config.longestEdge, 768)
    }

    func testParsesSigLIPHeightWidthSize() throws {
        let json = """
        {"size": {"height": 384, "width": 384}, "patch_size": 14}
        """.data(using: .utf8)!
        let config = try XCTUnwrap(Config.parse(json: json))
        XCTAssertEqual(config.imageSize, 384)
        XCTAssertEqual(config.patchSize, 14)
    }

    func testParsesScalarSize() throws {
        let json = #"{"size": 224}"#.data(using: .utf8)!
        let config = try XCTUnwrap(Config.parse(json: json))
        XCTAssertEqual(config.shortestEdge, 224)
    }

    func testParseReturnsNilForUnrelatedJSON() {
        let json = #"{"image_mean": [0.5], "do_normalize": true}"#.data(using: .utf8)!
        XCTAssertNil(Config.parse(json: json))
        XCTAssertNil(Config.parse(json: Data("not json".utf8)))
    }

    // MARK: - Smart resize (Qwen-VL style)

    func testSmartResizeKeepsMultipleOfFactor() throws {
        let planner = Planner(maxLongEdge: 4096)
        let config = Config(patchSize: 14, mergeSize: 2, minPixels: 3136,
                            maxPixels: 12_845_056)
        let plan = try planner.plan(source: Size(width: 1920, height: 1080),
                                    config: config)
        XCTAssertEqual(plan.target.width % 28, 0)
        XCTAssertEqual(plan.target.height % 28, 0)
        XCTAssertEqual(plan.rule, "smart-resize")
    }

    func testSmartResizeClampsToMaxPixels() throws {
        let planner = Planner(maxLongEdge: 4096)
        let config = Config(patchSize: 14, mergeSize: 2, maxPixels: 401_408)
        let plan = try planner.plan(source: Size(width: 4000, height: 3000),
                                    config: config)
        XCTAssertLessThanOrEqual(plan.target.pixels, 401_408)
    }

    func testSmartResizeHonorsMinPixels() throws {
        let planner = Planner(maxLongEdge: 4096)
        let config = Config(patchSize: 14, mergeSize: 2, minPixels: 250_000,
                            maxPixels: 12_845_056)
        let plan = try planner.plan(source: Size(width: 200, height: 150),
                                    config: config)
        XCTAssertGreaterThanOrEqual(plan.target.pixels, 250_000 - 28 * 28 * 4)
    }

    func testSmartResizePreservesAspectRoughly() throws {
        let planner = Planner(maxLongEdge: 4096)
        let config = Config(patchSize: 14, mergeSize: 2, maxPixels: 401_408)
        let plan = try planner.plan(source: Size(width: 2000, height: 1000),
                                    config: config)
        let sourceAspect = 2.0
        let targetAspect = Double(plan.target.width) / Double(plan.target.height)
        XCTAssertEqual(targetAspect, sourceAspect, accuracy: 0.35)
    }

    // MARK: - Device cap

    func testAbsoluteLongEdgeCapApplies() throws {
        let planner = Planner(maxLongEdge: 1536)
        let config = Config(patchSize: 14, mergeSize: 2,
                            maxPixels: 12_845_056)
        let plan = try planner.plan(source: Size(width: 8000, height: 6000),
                                    config: config)
        XCTAssertLessThanOrEqual(plan.target.longEdge, 1536)
    }

    func testFixedSquareCappedByDeviceLimit() throws {
        let planner = Planner(maxLongEdge: 1024)
        let config = Config(patchSize: 14, imageSize: 1536)
        let plan = try planner.plan(source: Size(width: 6000, height: 4000),
                                    config: config)
        XCTAssertEqual(plan.target, Size(width: 1024, height: 1024))
        XCTAssertEqual(plan.rule, "fixed")
    }

    func testShortestEdgeTarget() throws {
        let planner = Planner()
        let config = Config(shortestEdge: 384, longestEdge: 768)
        let plan = try planner.plan(source: Size(width: 1920, height: 1080),
                                    config: config)
        XCTAssertEqual(plan.target.height, 384)
        XCTAssertLessThanOrEqual(plan.target.width, 768)
    }

    // MARK: - Token + buffer estimates

    func testTokenEstimateMatchesPatchGrid() throws {
        let planner = Planner(maxLongEdge: 4096)
        let config = Config(patchSize: 14, mergeSize: 2, maxPixels: 12_845_056)
        let plan = try planner.plan(source: Size(width: 1120, height: 560),
                                    config: config)
        XCTAssertEqual(plan.estimatedTokens,
                       (plan.target.height / 28) * (plan.target.width / 28))
        XCTAssertEqual(plan.bufferBytes, Int64(plan.target.pixels) * 4)
    }

    func testFixedTokenEstimate() throws {
        let planner = Planner()
        let config = Config(patchSize: 14, imageSize: 448)
        let plan = try planner.plan(source: Size(width: 3000, height: 2000),
                                    config: config)
        // 448/14 = 32 → 1024 tokens (PaliGemma 448).
        XCTAssertEqual(plan.estimatedTokens, 1024)
    }

    // MARK: - Failure paths

    func testZeroSizeRejected() {
        let planner = Planner()
        XCTAssertThrowsError(try planner.plan(source: Size(width: 0, height: 100),
                                              config: Config()))
    }

    func testExtremeAspectRejected() {
        let planner = Planner()
        XCTAssertThrowsError(try planner.plan(source: Size(width: 40_000, height: 100),
                                              config: Config())) { error in
            guard case Planner.PlannerError.unusableSource = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testEmptyConfigUsesFallbackBudget() throws {
        let planner = Planner()
        let plan = try planner.plan(source: Size(width: 6000, height: 4000),
                                    config: Config())
        XCTAssertLessThanOrEqual(plan.target.pixels, planner.fallbackMaxPixels + 28 * 28)
    }
}

final class VLMTypeRegistryTests: XCTestCase {
    func testKnownTypesAreRatedSupported() {
        for known in VLMTypeRegistry.knownTypes {
            let rating = VLMTypeRegistry.rate(
                modality: .visionLanguage, formats: [.mlx],
                architecture: known.modelType)
            guard case .supported = rating else {
                return XCTFail("\(known.modelType) should be supported, got \(rating)")
            }
        }
    }

    func testLookupIsCaseInsensitive() {
        XCTAssertNotNil(VLMTypeRegistry.lookup("Qwen2_VL"))
        XCTAssertNil(VLMTypeRegistry.lookup("definitely_not_a_vlm"))
    }

    func testUnknownArchitectureIsUnsupportedWithReason() {
        let rating = VLMTypeRegistry.rate(modality: .visionLanguage, formats: [.mlx],
                                          architecture: "fictional_vl_9000")
        guard case .unsupported(let reason) = rating else {
            return XCTFail("expected unsupported, got \(rating)")
        }
        XCTAssertTrue(reason.contains("fictional_vl_9000"))
    }

    func testMissingArchitectureIsRisky() {
        let rating = VLMTypeRegistry.rate(modality: .visionLanguage, formats: [.mlx],
                                          architecture: nil)
        guard case .risky = rating else {
            return XCTFail("expected risky, got \(rating)")
        }
    }

    func testWrongModalityAndFormatRejected() {
        guard case .unsupported = VLMTypeRegistry.rate(
            modality: .text, formats: [.mlx], architecture: "qwen2_vl") else {
            return XCTFail("text modality must be unsupported")
        }
        guard case .unsupported = VLMTypeRegistry.rate(
            modality: .visionLanguage, formats: [.gguf], architecture: "qwen2_vl") else {
            return XCTFail("GGUF format must be unsupported")
        }
    }

    func testMultiImageLimits() {
        XCTAssertEqual(VLMTypeRegistry.maxImagesPerRequest(for: "qwen2_vl"), 4)
        XCTAssertEqual(VLMTypeRegistry.maxImagesPerRequest(for: "paligemma"), 1)
        XCTAssertEqual(VLMTypeRegistry.maxImagesPerRequest(for: nil), 1)
    }

    func testVideoInputSupport() {
        XCTAssertTrue(VLMTypeRegistry.supportsVideoInput(for: "qwen2_5_vl"))
        XCTAssertFalse(VLMTypeRegistry.supportsVideoInput(for: "gemma3"))
        XCTAssertFalse(VLMTypeRegistry.supportsVideoInput(for: nil))
    }
}

final class VisionCompatibilityProbeTests: XCTestCase {
    typealias Size = ImagePreprocessingPlanner.PixelSize

    func testEstimateAggregatesAcrossImages() {
        let probe = VisionCompatibilityProbe()
        let config = ImagePreprocessingPlanner.ProcessorConfig(
            patchSize: 14, mergeSize: 2, maxPixels: 401_408)
        let estimate = probe.estimate(
            sources: [Size(width: 4000, height: 3000), Size(width: 800, height: 600)],
            config: config)
        XCTAssertEqual(estimate.plans.count, 2)
        XCTAssertTrue(estimate.anyDownsampled)
        XCTAssertEqual(estimate.totalEstimatedTokens,
                       estimate.plans.reduce(0) { $0 + $1.estimatedTokens })
        XCTAssertGreaterThan(estimate.totalBufferBytes, 0)
    }

    func testUnplannableImagesAreDropped() {
        let probe = VisionCompatibilityProbe()
        let estimate = probe.estimate(
            sources: [Size(width: 0, height: 0), Size(width: 100, height: 100)],
            config: .init())
        XCTAssertEqual(estimate.plans.count, 1)
    }

    func testContextFitCheck() {
        let probe = VisionCompatibilityProbe()
        let estimate = probe.estimate(
            sources: [Size(width: 1120, height: 1120)], config: .init())
        XCTAssertTrue(VisionCompatibilityProbe.fitsContext(
            estimate: estimate, promptTokens: 100, contextLength: 32_768))
        XCTAssertFalse(VisionCompatibilityProbe.fitsContext(
            estimate: estimate, promptTokens: 100, contextLength: 512))
        // Unknown context never refuses.
        XCTAssertTrue(VisionCompatibilityProbe.fitsContext(
            estimate: estimate, promptTokens: 100, contextLength: nil))
    }
}
