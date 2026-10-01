import XCTest
@testable import LocallyRuntime
import LocallyCore

final class DiffusionPlannerTests: XCTestCase {

    private let planner = DiffusionPlanner()

    private func coreMLDiffusion(resolution: Int = 512) -> ModelDescriptor {
        var metadata: [String: String] = [
            "diffusion_attention": "split_einsum",
            "diffusion_form": "zip",
            "diffusion_resources_dir": "model_split_einsum_v2_compiled",
            "diffusion_resolution": "\(resolution)",
        ]
        metadata["revision"] = "abc"
        return ModelDescriptor(
            repoID: "apple/coreml-stable-diffusion-2-1-base-palettized",
            name: "coreml-stable-diffusion-2-1-base-palettized",
            modality: .imageGeneration,
            formats: [.coreml],
            totalDownloadSize: 1_141_379_936,
            requiredFiles: [RemoteModelFile(
                path: "coreml-stable-diffusion-2-1-base-palettized_split_einsum_v2_compiled.zip",
                size: 1_141_379_936)],
            estimatedWeightMemory: 1_141_379_936,
            supportedRuntimes: [.diffusion],
            architectureHints: ArchitectureHints(diffusionResolution: resolution),
            metadata: metadata
        )
    }

    func testValidRequestProducesConcreteSeed() throws {
        let plan = try planner.plan(.init(prompt: "a red fox", seed: 42), for: coreMLDiffusion())
        XCTAssertEqual(plan.seed, 42)
        XCTAssertFalse(plan.seedWasRandom)
        XCTAssertEqual(plan.stepCount, 20)
        XCTAssertEqual(plan.resolution, 512)
        XCTAssertEqual(plan.attention, "split_einsum")
        XCTAssertTrue(plan.warnings.isEmpty)
        XCTAssertNotNil(plan.estimatedMemoryBytes)
    }

    func testNilSeedIsRandomizedAndMarked() throws {
        let plan = try planner.plan(.init(prompt: "a red fox"), for: coreMLDiffusion(),
                                    randomSource: { 12345 })
        XCTAssertEqual(plan.seed, 12345)
        XCTAssertTrue(plan.seedWasRandom)
    }

    func testEmptyPromptRejected() {
        XCTAssertThrowsError(try planner.plan(.init(prompt: "   "), for: coreMLDiffusion())) {
            XCTAssertEqual($0 as? DiffusionPlanner.PlanError, .emptyPrompt)
        }
    }

    func testStepCountBoundsEnforced() {
        XCTAssertThrowsError(try planner.plan(.init(prompt: "x", stepCount: 0),
                                              for: coreMLDiffusion())) {
            XCTAssertEqual($0 as? DiffusionPlanner.PlanError, .stepCountOutOfRange(0))
        }
        XCTAssertThrowsError(try planner.plan(.init(prompt: "x", stepCount: 51),
                                              for: coreMLDiffusion()))
    }

    func testGuidanceBoundsEnforced() {
        XCTAssertThrowsError(try planner.plan(.init(prompt: "x", guidanceScale: 0.5),
                                              for: coreMLDiffusion())) {
            XCTAssertEqual($0 as? DiffusionPlanner.PlanError, .guidanceOutOfRange(0.5))
        }
        XCTAssertThrowsError(try planner.plan(.init(prompt: "x", guidanceScale: 25),
                                              for: coreMLDiffusion()))
    }

    func testSafetensorsDiffusionRejectedAsNeedingConversion() {
        let model = ModelDescriptor(
            repoID: "sd-community/tiny-sd", name: "tiny-sd",
            modality: .imageGeneration, formats: [.safetensors],
            metadata: ["unsupported_reason": "Needs Core ML conversion"])
        XCTAssertThrowsError(try planner.plan(.init(prompt: "x"), for: model)) {
            XCTAssertEqual($0 as? DiffusionPlanner.PlanError, .needsCoreMLConversion)
        }
    }

    func testNonDiffusionModalityRejected() {
        let model = ModelDescriptor(repoID: "a/b", name: "b", modality: .text,
                                    formats: [.gguf])
        XCTAssertThrowsError(try planner.plan(.init(prompt: "x"), for: model)) {
            XCTAssertEqual($0 as? DiffusionPlanner.PlanError, .notADiffusionModel)
        }
    }

    func testSDXLResolutionWarnsOnSmallDevices() throws {
        let plan = try planner.plan(.init(prompt: "x"), for: coreMLDiffusion(resolution: 1024),
                                    physicalMemory: 4 * 1024 * 1024 * 1024)
        XCTAssertEqual(plan.resolution, 1024)
        XCTAssertTrue(plan.warnings.contains { $0.contains("8 GB") })
    }

    func testHighStepCountWarns() throws {
        let plan = try planner.plan(.init(prompt: "x", stepCount: 40), for: coreMLDiffusion())
        XCTAssertTrue(plan.warnings.contains { $0.contains("slow") })
    }

    func testMemoryEstimateCoversWeightsPlusLatents() throws {
        let plan = try planner.plan(.init(prompt: "x"), for: coreMLDiffusion())
        let estimate = try XCTUnwrap(plan.estimatedMemoryBytes)
        XCTAssertGreaterThan(estimate, 1_141_379_936)
    }

    func testMemoryEstimateNilWithoutWeightInfo() throws {
        var model = coreMLDiffusion()
        model.estimatedWeightMemory = nil
        model.totalDownloadSize = nil
        let plan = try planner.plan(.init(prompt: "x"), for: model)
        XCTAssertNil(plan.estimatedMemoryBytes)
    }
}
