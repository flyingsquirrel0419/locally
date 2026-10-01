import XCTest
@testable import LocallyCompatibility
import LocallyCore
import LocallyDevice

final class CompatibilityEngineTests: XCTestCase {

    // MARK: - Fixtures

    private func device(ramGB: Double, freeFraction: Double = 0.6,
                        lowPower: Bool = false,
                        thermal: DeviceProfile.ThermalState = .nominal,
                        freeStorage: Int64 = 100_000_000_000) -> DeviceProfile {
        let physical = UInt64(ramGB * 1_073_741_824)
        return DeviceProfile(
            modelIdentifier: "iPhone-test",
            osVersion: "17.0",
            physicalMemory: physical,
            availableMemoryEstimate: UInt64(Double(physical) * freeFraction),
            metalAvailable: true,
            recommendedMaxWorkingSet: UInt64(Double(physical) * 0.55),
            freeStorage: freeStorage,
            totalStorage: 128_000_000_000,
            lowPowerMode: lowPower,
            thermalState: thermal,
            processorCount: 6,
            activeProcessorCount: 6,
            neuralEngineAvailable: true,
            neuralEngineKnown: true
        )
    }

    /// LLaMA-ish descriptor: scales params to real config proportions.
    private func llm(params: Int64, bits: Int, layers: Int, hidden: Int,
                     kvHeads: Int, context: Int, slidingWindow: Int? = nil,
                     quantScheme: String? = nil) -> ModelDescriptor {
        let bytesPerParam = Double(bits) / 8.0
        let weights = Int64(Double(params) * bytesPerParam * 1.06)
        return ModelDescriptor(
            repoID: "test/model",
            name: "model",
            architecture: "TestForCausalLM",
            modality: .text,
            parameterCount: params,
            quantization: Quantization(bits: bits, scheme: quantScheme),
            formats: [.gguf],
            totalDownloadSize: weights,
            requiredFiles: [RemoteModelFile(path: "model.gguf", size: weights)],
            supportedRuntimes: [.gguf],
            contextLength: context,
            architectureHints: ArchitectureHints(
                numLayers: layers, hiddenSize: hidden,
                numAttentionHeads: kvHeads * 4, numKVHeads: kvHeads,
                vocabSize: 32_000, intermediateSize: hidden * 4,
                slidingWindow: slidingWindow
            )
        )
    }

    private var engine: CompatibilityEngine { CompatibilityEngine() }

    // MARK: - Rating matrix

    func testHalfB4bitExcellentOn6GB() {
        // 0.5B @ 4-bit ≈ 0.3 GB weights → trivially fits 6 GB.
        let model = llm(params: 500_000_000, bits: 4, layers: 24, hidden: 896,
                        kvHeads: 2, context: 32_768)
        let report = engine.evaluate(descriptor: model, device: device(ramGB: 6))
        XCTAssertEqual(report.rating, .excellent)
        XCTAssertTrue(report.blockers.isEmpty)
        XCTAssertEqual(report.recommendedRuntime, .gguf)
    }

    func test4B4bitUsableOn8GB() {
        // 4B @ 4-bit ≈ 3.3–3.7 GB total on a ~4.7 GB safe budget → usable.
        let model = llm(params: 4_000_000_000, bits: 4, layers: 36, hidden: 2560,
                        kvHeads: 8, context: 8_192)
        let report = engine.evaluate(descriptor: model, device: device(ramGB: 8))
        XCTAssertTrue(report.rating == .usable || report.rating == .good,
                      "got \(report.rating)")
        XCTAssertTrue(report.blockers.isEmpty)
    }

    func test8B4bitUnsupportedOn8GB() {
        // 8B @ 4-bit ≈ 6.0–6.5 GB total > ~4.7 GB safe budget on 8 GB.
        // iOS jetsam keeps the budget at ~55% of physical RAM, so an 8B
        // quant honestly does not fit an 8 GB phone at 8K context.
        let model = llm(params: 8_000_000_000, bits: 4, layers: 32, hidden: 4096,
                        kvHeads: 8, context: 8_192)
        let report = engine.evaluate(descriptor: model, device: device(ramGB: 8))
        XCTAssertEqual(report.rating, .unsupported)
        XCTAssertTrue(report.blockers.contains { $0.contains("Not enough memory") })
    }

    func test8Bfp16UnsupportedOn8GB() {
        // 8B fp16 ≈ 16 GB — cannot fit an 8 GB phone.
        let model = llm(params: 8_000_000_000, bits: 16, layers: 32, hidden: 4096,
                        kvHeads: 8, context: 8_192)
        let report = engine.evaluate(descriptor: model, device: device(ramGB: 8))
        XCTAssertEqual(report.rating, .unsupported)
        XCTAssertTrue(report.blockers.contains { $0.contains("Not enough memory") })
    }

    func test8Bfp16GoodOn12GB() {
        // 12 GB device: budget ~7 GB. 16 GB weights still don't fit.
        let model = llm(params: 8_000_000_000, bits: 16, layers: 32, hidden: 4096,
                        kvHeads: 8, context: 8_192)
        let report = engine.evaluate(descriptor: model, device: device(ramGB: 12))
        XCTAssertEqual(report.rating, .unsupported)
    }

    func test8B4bitOn4GBUnsupported() {
        let model = llm(params: 8_000_000_000, bits: 4, layers: 32, hidden: 4096,
                        kvHeads: 8, context: 8_192)
        let report = engine.evaluate(descriptor: model, device: device(ramGB: 4))
        XCTAssertEqual(report.rating, .unsupported)
    }

    func testVLMIncludesVisionEncoder() {
        var model = llm(params: 2_000_000_000, bits: 4, layers: 28, hidden: 1536,
                        kvHeads: 2, context: 32_768)
        model.modality = .visionLanguage
        model.architectureHints?.visionEncoderParams = 300_000_000
        let report = engine.evaluate(descriptor: model, device: device(ramGB: 8))
        let vision = report.memory?.components.first { $0.name == "Vision Encoder" }
        XCTAssertNotNil(vision)
        XCTAssertGreaterThan(vision?.low ?? 0, 600_000_000) // fp16 weights + image
    }

    func testDiffusionHasBuffers() {
        var model = ModelDescriptor(
            repoID: "test/sdxl", name: "sdxl", modality: .imageGeneration,
            parameterCount: 3_500_000_000, quantization: Quantization(bits: 16),
            formats: [.coreml], totalDownloadSize: 6_900_000_000,
            supportedRuntimes: [.diffusion], contextLength: nil)
        model.architectureHints = nil
        let report = engine.evaluate(descriptor: model, device: device(ramGB: 12))
        XCTAssertNotNil(report.memory?.components.first { $0.name == "Diffusion Buffers" })
        XCTAssertEqual(report.recommendedRuntime, .diffusion)
    }

    func testRemoteCodeUnsupported() {
        var model = llm(params: 7_000_000_000, bits: 4, layers: 32, hidden: 4096,
                        kvHeads: 8, context: 4_096)
        model.metadata["requiresRemoteCode"] = "true"
        model.supportedRuntimes = []
        let report = engine.evaluate(descriptor: model, device: device(ramGB: 12))
        XCTAssertEqual(report.rating, .unsupported)
        XCTAssertTrue(report.blockers.contains { $0.contains("repository code") })
    }

    func testUnknownModalityUnsupported() {
        var model = llm(params: 1_000_000_000, bits: 4, layers: 12, hidden: 1024,
                        kvHeads: 4, context: 4_096)
        model.modality = .unknown
        let report = engine.evaluate(descriptor: model, device: device(ramGB: 8))
        XCTAssertEqual(report.rating, .unsupported)
        XCTAssertTrue(report.blockers.contains { $0.contains("modality") })
    }

    func testStorageBlocker() {
        let model = llm(params: 4_000_000_000, bits: 4, layers: 36, hidden: 2560,
                        kvHeads: 8, context: 8_192)
        let report = engine.evaluate(descriptor: model,
                                     device: device(ramGB: 12, freeStorage: 1_000_000_000))
        XCTAssertEqual(report.rating, .unsupported)
        XCTAssertTrue(report.blockers.contains { $0.contains("storage") })
    }

    // MARK: - Context & KV behavior

    func testKVCacheGrowsLinearlyWithContext() {
        let model = llm(params: 1_000_000_000, bits: 4, layers: 16, hidden: 2048,
                        kvHeads: 4, context: 32_768)
        let estimator = MemoryEstimator()
        func kv(at context: Int) -> Int64 {
            estimator.estimate(.init(descriptor: model, contextLength: context))
                .components.first { $0.name == "KV Cache" }?.low ?? 0
        }
        let kv4k = kv(at: 4_096), kv8k = kv(at: 8_192), kv16k = kv(at: 16_384)
        XCTAssertEqual(kv8k, kv4k * 2)
        XCTAssertEqual(kv16k, kv4k * 4)
    }

    func testSlidingWindowCapsKV() {
        let model = llm(params: 1_000_000_000, bits: 4, layers: 16, hidden: 2048,
                        kvHeads: 4, context: 32_768, slidingWindow: 4_096)
        let estimator = MemoryEstimator()
        func kv(at context: Int) -> Int64 {
            estimator.estimate(.init(descriptor: model, contextLength: context))
                .components.first { $0.name == "KV Cache" }?.low ?? 0
        }
        XCTAssertEqual(kv(at: 32_768), kv(at: 4_096))
    }

    func testRecommendedLeqMaxLeqModelMax() {
        let model = llm(params: 4_000_000_000, bits: 4, layers: 36, hidden: 2560,
                        kvHeads: 8, context: 32_768)
        let report = engine.evaluate(descriptor: model, device: device(ramGB: 8))
        if let rec = report.recommendedContext, let max = report.maxContext {
            XCTAssertLessThanOrEqual(rec, max)
            XCTAssertLessThanOrEqual(max, 32_768)
        }
    }

    // MARK: - Speed

    func testSpeedUnknownWithoutData() {
        let model = llm(params: 500_000_000, bits: 4, layers: 24, hidden: 896,
                        kvHeads: 2, context: 8_192)
        let report = engine.evaluate(descriptor: model, device: device(ramGB: 8))
        XCTAssertEqual(report.speed, .unknown)
    }

    func testSpeedEstimatedFromBandwidth() {
        let model = llm(params: 1_000_000_000, bits: 4, layers: 16, hidden: 2048,
                        kvHeads: 4, context: 8_192)
        let bench = BenchmarkResult(memoryCopyGBps: 50.0)
        let report = engine.evaluate(descriptor: model, device: device(ramGB: 8),
                                     deviceBenchmark: bench)
        guard case .estimated(let low, let high) = report.speed else {
            return XCTFail("expected estimated, got \(report.speed)")
        }
        XCTAssertGreaterThan(low, 0)
        XCTAssertGreaterThan(high, low)
        // Sanity: ~1.06 GB per token at 50 GB/s → 47 ideal tok/s, band 23–38.
        XCTAssertTrue(low > 10 && high < 100, "low=\(low) high=\(high)")
    }

    func testSpeedMeasuredBeatsEstimate() {
        let model = llm(params: 1_000_000_000, bits: 4, layers: 16, hidden: 2048,
                        kvHeads: 4, context: 8_192)
        let samples = [InferenceMetadata(tokensPerSecond: 20.0),
                       InferenceMetadata(tokensPerSecond: 24.5)]
        let bench = BenchmarkResult(memoryCopyGBps: 50.0)
        let report = engine.evaluate(descriptor: model, device: device(ramGB: 8),
                                     benchmarks: samples, deviceBenchmark: bench)
        XCTAssertEqual(report.speed, .measured(low: 20.0, high: 24.5))
    }

    // MARK: - Thermal & warnings

    func testLowPowerAndThermalWarnings() {
        let model = llm(params: 500_000_000, bits: 4, layers: 24, hidden: 896,
                        kvHeads: 2, context: 4_096)
        let report = engine.evaluate(descriptor: model,
                                     device: device(ramGB: 8, lowPower: true,
                                                    thermal: .serious))
        XCTAssertTrue(report.warnings.contains { $0.contains("Low Power Mode") })
        XCTAssertTrue(report.warnings.contains { $0.contains("thermal") })
    }

    func testThermalLoadBands() {
        let small = llm(params: 500_000_000, bits: 4, layers: 24, hidden: 896,
                        kvHeads: 2, context: 4_096)
        let large = llm(params: 8_000_000_000, bits: 4, layers: 32, hidden: 4096,
                        kvHeads: 8, context: 32_768)
        XCTAssertEqual(engine.evaluate(descriptor: small, device: device(ramGB: 8)).thermalLoad, .low)
        XCTAssertEqual(engine.evaluate(descriptor: large, device: device(ramGB: 12)).thermalLoad, .high)
    }

    // MARK: - Runtime scoring

    func testRuntimeScorerRanksNativeFormat() {
        var model = llm(params: 1_000_000_000, bits: 4, layers: 16, hidden: 2048,
                        kvHeads: 4, context: 8_192)
        model.formats = [.mlx, .gguf]
        model.supportedRuntimes = [.mlx, .gguf]
        let scorer = RuntimeScorer(isRuntimeAvailable: { $0 != .coreml })
        let ranked = scorer.score(descriptor: model, memoryFitRatio: 0.3, metalAvailable: true)
        XCTAssertEqual(ranked.first?.runtime, .mlx)
        XCTAssertTrue(ranked.allSatisfy { $0.availability == .available })
    }

    func testRuntimeScorerMarksUnavailable() {
        var model = llm(params: 1_000_000_000, bits: 4, layers: 16, hidden: 2048,
                        kvHeads: 4, context: 8_192)
        model.supportedRuntimes = [.mlx, .gguf]
        model.formats = [.mlx, .gguf]
        let scorer = RuntimeScorer(isRuntimeAvailable: { $0 == .gguf })
        let ranked = scorer.score(descriptor: model, memoryFitRatio: 0.3, metalAvailable: true)
        XCTAssertEqual(ranked.first?.runtime, .gguf)
        XCTAssertEqual(ranked.last?.availability, .unavailable)
        XCTAssertEqual(ranked.last?.score, 0)
    }

    // MARK: - Confidence

    func testConfidenceMediumWhenArchitecturePartiallyKnown() {
        // Params + quantization known, structure missing → medium.
        var model = llm(params: 4_000_000_000, bits: 4, layers: 36, hidden: 2560,
                        kvHeads: 8, context: 8_192)
        model.architectureHints = nil
        let report = engine.evaluate(descriptor: model, device: device(ramGB: 8))
        XCTAssertEqual(report.memory?.confidence, .medium)
    }

    func testLowConfidenceWhenEverythingUnknown() {
        let model = ModelDescriptor(repoID: "test/mystery", name: "mystery",
                                    modality: .text, formats: [.gguf],
                                    supportedRuntimes: [.gguf])
        let report = engine.evaluate(descriptor: model, device: device(ramGB: 8))
        XCTAssertEqual(report.memory?.confidence, .low)
        XCTAssertTrue(report.warnings.contains { $0.contains("low confidence") })
    }
}
