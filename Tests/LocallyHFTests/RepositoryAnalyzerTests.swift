import XCTest
@testable import LocallyHF
import LocallyCore

final class RepositoryAnalyzerTests: XCTestCase {
    private let analyzer = RepositoryAnalyzer()

    private func reference(_ id: String) throws -> HFRepoReference {
        try HFRepoReference(parsing: id)
    }

    private func configs(for directory: String) throws -> [String: ModelConfig] {
        var result: [String: ModelConfig] = [:]
        for name in ["config.json", "model_index.json"] {
            if let config = try Fixtures.config(directory, name) {
                result[name] = config
            }
        }
        return result
    }

    func testMLXTextModel() throws {
        let info = try Fixtures.repoInfo("mlx-qwen")
        let stHeader = try ModelHeaderParser.parseSafetensors(
            Fixtures.data("mlx-qwen/safetensors_header.bin"))
        let descriptor = analyzer.analyze(
            info: info, configs: try configs(for: "mlx-qwen"),
            frontMatter: try Fixtures.readme("mlx-qwen"),
            safetensorsHeader: stHeader,
            reference: try reference("mlx-community/Qwen2.5-0.5B-Instruct-4bit")
        )
        XCTAssertEqual(descriptor.modality, .text)
        XCTAssertEqual(descriptor.architecture, "Qwen2ForCausalLM")
        XCTAssertTrue(descriptor.formats.contains(.mlx))
        XCTAssertFalse(descriptor.formats.contains(.gguf))
        XCTAssertEqual(descriptor.quantization?.bits, 4)
        XCTAssertEqual(descriptor.parameterCount, 276_627_456)
        XCTAssertEqual(descriptor.contextLength, 32768)
        XCTAssertEqual(descriptor.supportedRuntimes, [.mlx])
        XCTAssertEqual(descriptor.metadata["license"], "apache-2.0")
        XCTAssertNil(descriptor.metadata["requiresRemoteCode"])

        // Weight files + tokenizer/configs, but not README/.gitattributes
        let paths = descriptor.requiredFiles.map(\.path)
        XCTAssertTrue(paths.contains("model.safetensors"))
        XCTAssertTrue(paths.contains("config.json"))
        XCTAssertTrue(paths.contains("tokenizer.json"))
        XCTAssertFalse(paths.contains("README.md"))
        XCTAssertFalse(paths.contains(".gitattributes"))
        XCTAssertEqual(descriptor.totalDownloadSize,
                       descriptor.requiredFiles.reduce(0) { $0 + $1.size })
        XCTAssertEqual(descriptor.estimatedWeightMemory, descriptor.totalDownloadSize)

        // Architecture hints read straight from config.json.
        let hints = try XCTUnwrap(descriptor.architectureHints)
        XCTAssertEqual(hints.numLayers, 24)
        XCTAssertEqual(hints.hiddenSize, 896)
        XCTAssertEqual(hints.numAttentionHeads, 14)
        XCTAssertEqual(hints.numKVHeads, 2)
        XCTAssertEqual(hints.vocabSize, 151936)
        XCTAssertEqual(hints.intermediateSize, 4864)
        XCTAssertEqual(hints.effectiveHeadDim, 64)
        XCTAssertEqual(hints.kvCacheDTypeBytes, 2)
    }

    func testGGUFVariantSelection() throws {
        let info = try Fixtures.repoInfo("gguf-qwen")
        let descriptor = analyzer.analyze(
            info: info, configs: [:], frontMatter: try Fixtures.readme("gguf-qwen"),
            safetensorsHeader: nil,
            reference: try reference("Qwen/Qwen2.5-0.5B-Instruct-GGUF")
        )
        XCTAssertEqual(descriptor.modality, .text)
        XCTAssertTrue(descriptor.formats.contains(.gguf))
        XCTAssertEqual(descriptor.quantization?.scheme, "Q4_K_M")

        // Only the Q4_K_M file is required.
        let weightFiles = descriptor.requiredFiles.filter { $0.path.hasSuffix(".gguf") }
        XCTAssertEqual(weightFiles.count, 1)
        XCTAssertTrue(weightFiles[0].path.contains("q4_k_m"))
        XCTAssertEqual(descriptor.totalDownloadSize, 397_000_000)
        XCTAssertEqual(descriptor.supportedRuntimes, [.gguf])

        // Non-runtime artifacts are excluded: llama.cpp importance-matrix
        // calibration data (quant tooling, not inference), licenses, images,
        // docs, VCS attributes.
        let paths = descriptor.requiredFiles.map(\.path)
        XCTAssertFalse(paths.contains { $0.hasSuffix(".imatrix") })
        XCTAssertFalse(paths.contains("LICENSE"))
        XCTAssertFalse(paths.contains("thumbnail.png"))
        XCTAssertFalse(paths.contains("README.md"))
        XCTAssertFalse(paths.contains(".gitattributes"))

        // Param count falls back to the "0.5B" name hint.
        XCTAssertEqual(descriptor.parameterCount, 500_000_000)
    }

    func testVisionLanguageModel() throws {
        let info = try Fixtures.repoInfo("qwen2-vl")
        let descriptor = analyzer.analyze(
            info: info, configs: try configs(for: "qwen2-vl"), frontMatter: nil,
            safetensorsHeader: nil,
            reference: try reference("Qwen/Qwen2-VL-2B-Instruct")
        )
        XCTAssertEqual(descriptor.modality, .visionLanguage)
        XCTAssertEqual(descriptor.architecture, "Qwen2VLForConditionalGeneration")
        XCTAssertTrue(descriptor.formats.contains(.safetensors))
        XCTAssertEqual(descriptor.contextLength, 32768)
        // Sharded weights both required; demo.jpg excluded.
        let paths = descriptor.requiredFiles.map(\.path)
        XCTAssertTrue(paths.contains("model-00001-of-00002.safetensors"))
        XCTAssertTrue(paths.contains("model-00002-of-00002.safetensors"))
        XCTAssertTrue(paths.contains("model.safetensors.index.json"))
        XCTAssertFalse(paths.contains("demo.jpg"))

        // VLM hints: text tower fields plus a vision encoder estimate from
        // vision_config (32 layers × (4h² + 2h·intermediate=4h)).
        let hints = try XCTUnwrap(descriptor.architectureHints)
        XCTAssertEqual(hints.numLayers, 28)
        XCTAssertEqual(hints.hiddenSize, 1536)
        XCTAssertEqual(hints.numKVHeads, 2)
        let vh = Int64(1536)
        XCTAssertEqual(hints.visionEncoderParams, 32 * (4 * vh * vh + 2 * vh * 4 * vh))
    }

    func testDiffusionModel() throws {
        let info = try Fixtures.repoInfo("diffusion-sd")
        let descriptor = analyzer.analyze(
            info: info, configs: try configs(for: "diffusion-sd"), frontMatter: nil,
            safetensorsHeader: nil,
            reference: try reference("sd-community/tiny-sd")
        )
        XCTAssertEqual(descriptor.modality, .imageGeneration)
        // Diffusers-format (safetensors UNet) repos cannot run on-device:
        // honestly unsupported until converted to Core ML.
        XCTAssertEqual(descriptor.supportedRuntimes, [])
        XCTAssertNotNil(descriptor.metadata["unsupported_reason"])
        let paths = descriptor.requiredFiles.map(\.path)
        XCTAssertTrue(paths.contains("unet/diffusion_pytorch_model.safetensors"))
        XCTAssertTrue(paths.contains("vae/diffusion_pytorch_model.safetensors"))
    }

    func testCoreMLDiffusionPicksSplitEinsumArchiveVariant() throws {
        let info = try Fixtures.repoInfo("diffusion-coreml")
        let descriptor = analyzer.analyze(
            info: info, configs: [:], frontMatter: nil, safetensorsHeader: nil,
            reference: try reference("apple/coreml-stable-diffusion-2-1-base-palettized")
        )
        XCTAssertEqual(descriptor.modality, .imageGeneration)
        XCTAssertTrue(descriptor.formats.contains(.coreml))
        XCTAssertEqual(descriptor.supportedRuntimes, [.diffusion])
        XCTAssertEqual(descriptor.metadata["diffusion_attention"], "split_einsum")
        XCTAssertEqual(descriptor.metadata["diffusion_form"], "zip")
        XCTAssertEqual(descriptor.metadata["diffusion_palettized"], "true")
        XCTAssertEqual(descriptor.metadata["diffusion_resolution"], "512")
        XCTAssertEqual(descriptor.architectureHints?.diffusionResolution, 512)
        // Exactly the chosen archive, nothing from either variant folder.
        let paths = descriptor.requiredFiles.map(\.path)
        XCTAssertEqual(paths,
            ["coreml-stable-diffusion-2-1-base-palettized_split_einsum_v2_compiled.zip"])
        XCTAssertEqual(descriptor.totalDownloadSize, 1141379936)
    }

    func testNonCoreMLDiffusionIsHonestlyUnsupported() throws {
        let info = try Fixtures.repoInfo("diffusion-sd")
        let descriptor = analyzer.analyze(
            info: info, configs: try configs(for: "diffusion-sd"), frontMatter: nil,
            safetensorsHeader: nil,
            reference: try reference("sd-community/tiny-sd")
        )
        XCTAssertEqual(descriptor.modality, .imageGeneration)
        XCTAssertEqual(descriptor.supportedRuntimes, [])
        XCTAssertNotNil(descriptor.metadata["unsupported_reason"])
    }

    func testWhisperSpeechRecognition() throws {
        let info = try Fixtures.repoInfo("whisper")
        let descriptor = analyzer.analyze(
            info: info, configs: try configs(for: "whisper"), frontMatter: nil,
            safetensorsHeader: nil,
            reference: try reference("openai/whisper-tiny")
        )
        XCTAssertEqual(descriptor.modality, .speechRecognition)
        XCTAssertEqual(descriptor.supportedRuntimes, [.audio])
        // safetensors chosen over pytorch_model.bin and onnx duplicates
        let paths = descriptor.requiredFiles.map(\.path)
        XCTAssertTrue(paths.contains("model.safetensors"))
        XCTAssertFalse(paths.contains("pytorch_model.bin"))
        XCTAssertFalse(paths.contains("onnx/model.onnx"))
    }

    func testSentenceTransformersEmbedding() throws {
        let info = try Fixtures.repoInfo("st-embedding")
        let descriptor = analyzer.analyze(
            info: info, configs: try configs(for: "st-embedding"), frontMatter: nil,
            safetensorsHeader: nil,
            reference: try reference("sentence-transformers/all-MiniLM-L6-v2")
        )
        XCTAssertEqual(descriptor.modality, .embedding)
        let paths = descriptor.requiredFiles.map(\.path)
        XCTAssertTrue(paths.contains("model.safetensors"))
        XCTAssertFalse(paths.contains("pytorch_model.bin"))
    }

    func testTrustRemoteCodeFlaggedUnsupported() throws {
        let info = try Fixtures.repoInfo("remote-code")
        let descriptor = analyzer.analyze(
            info: info, configs: try configs(for: "remote-code"), frontMatter: nil,
            safetensorsHeader: nil,
            reference: try reference("acme/experimental-chat-7b")
        )
        XCTAssertEqual(descriptor.metadata["requiresRemoteCode"], "true")
        XCTAssertTrue(descriptor.supportedRuntimes.isEmpty,
                      "remote-code models must report no supported runtimes")
    }

    func testParameterEstimationFromConfig() throws {
        // LLaMA-ish: hidden 896, layers 24, intermediate 4864, vocab 151936,
        // heads 14, kv 2, tied embeddings (the mlx-qwen fixture config).
        let config = try XCTUnwrap(Fixtures.config("mlx-qwen"))
        let estimate = analyzer.estimateParametersFromConfig(config)
        XCTAssertNotNil(estimate)
        // headDim = 64; q = 896*896; kv = 2*896*128; o = 896*896
        // attention = 802816 + 229376 + 802816 = 1_835_008? verify directly below.
        let h: Int64 = 896, l: Int64 = 24, v: Int64 = 151936, i: Int64 = 4864
        let attention = h * (14 * 64) + 2 * h * (2 * 64) + (14 * 64) * h
        let mlp = 3 * h * i
        let expected = v * h + l * (attention + mlp) // tied embeddings -> no lm_head
        XCTAssertEqual(estimate, expected)
    }

    func testNameHintParameterEstimation() {
        XCTAssertEqual(analyzer.estimateParametersFromName("Qwen2.5-0.5B-Instruct"), 500_000_000)
        XCTAssertEqual(analyzer.estimateParametersFromName("Llama-3.1-8B"), 8_000_000_000)
        XCTAssertEqual(analyzer.estimateParametersFromName("all-MiniLM-L6-v2"), nil)
    }

    func testSafetensorsHeaderParsing() throws {
        let data = try Fixtures.data("mlx-qwen/safetensors_header.bin")
        let header = try ModelHeaderParser.parseSafetensors(data)
        XCTAssertEqual(header.parameterCount, 276_627_456)
        XCTAssertEqual(header.dtypes["F16"], 272_269_312)
        XCTAssertEqual(header.dtypes["U4"], 4_358_144)
    }

    func testSafetensorsHeaderRejectsTruncated() {
        XCTAssertThrowsError(try ModelHeaderParser.parseSafetensors(Data([1, 2, 3])))
    }

    func testGGUFHeaderParsing() throws {
        var bytes = Data()
        bytes.append(contentsOf: [0x47, 0x47, 0x55, 0x46]) // "GGUF" LE
        bytes.append(contentsOf: withUnsafeBytes(of: UInt32(3).littleEndian, Array.init))
        bytes.append(contentsOf: withUnsafeBytes(of: UInt64(291).littleEndian, Array.init))
        bytes.append(contentsOf: withUnsafeBytes(of: UInt64(17).littleEndian, Array.init))
        let header = try ModelHeaderParser.parseGGUFHeader(bytes)
        XCTAssertEqual(header.version, 3)
        XCTAssertEqual(header.tensorCount, 291)
        XCTAssertEqual(header.metadataCount, 17)
    }

    func testGGUFHeaderRejectsBadMagic() {
        var bytes = Data(repeating: 0, count: 24)
        bytes.replaceSubrange(0..<4, with: [0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertThrowsError(try ModelHeaderParser.parseGGUFHeader(bytes))
    }

    func testFrontMatterParsing() throws {
        let card = try XCTUnwrap(Fixtures.readme("mlx-qwen"))
        XCTAssertEqual(card.pipelineTag, "text-generation")
        XCTAssertEqual(card.libraryName, "mlx")
        XCTAssertEqual(card.license, "apache-2.0")
        XCTAssertTrue(card.tags.contains("qwen2"))

        let inline = CardFrontMatter(markdown: """
        ---
        tags: [gguf, llama-cpp]
        license: "mit"
        ---
        body
        """)
        XCTAssertEqual(inline.tags, ["gguf", "llama-cpp"])
        XCTAssertEqual(inline.license, "mit")

        let none = CardFrontMatter(markdown: "# Just a title")
        XCTAssertNil(none.pipelineTag)
        XCTAssertTrue(none.tags.isEmpty)
    }
}
