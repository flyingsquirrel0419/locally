import XCTest
@testable import LocallyCore

final class QuantizationTests: XCTestCase {
    func testParsesGGUFScheme() {
        let q = Quantization.parse("Q4_K_M")
        XCTAssertEqual(q?.bits, 4)
        XCTAssertEqual(q?.scheme, "Q4_K_M")
    }

    func testParsesInt8() {
        XCTAssertEqual(Quantization.parse("int8")?.bits, 8)
    }

    func testParsesFp16() {
        XCTAssertEqual(Quantization.parse("fp16")?.bits, 16)
        XCTAssertEqual(Quantization.parse("bf16")?.bits, 16)
    }

    func testParsesBitSuffix() {
        XCTAssertEqual(Quantization.parse("4bit")?.bits, 4)
        XCTAssertEqual(Quantization.parse("8-bit")?.bits, 8)
    }

    func testRejectsGarbage() {
        XCTAssertNil(Quantization.parse(""))
        XCTAssertNil(Quantization.parse("not-a-quant"))
    }

    func testBytesPerParameter() {
        XCTAssertEqual(Quantization(bits: 4).bytesPerParameter, 0.5)
        XCTAssertEqual(Quantization(bits: 16).bytesPerParameter, 2.0)
    }
}

final class ModelDescriptorTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let descriptor = ModelDescriptor(
            repoID: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            name: "Qwen2.5-0.5B-Instruct-4bit",
            architecture: "qwen2",
            modality: .text,
            parameterCount: 500_000_000,
            quantization: Quantization(bits: 4, scheme: "af4_0"),
            formats: [.mlx, .safetensors],
            totalDownloadSize: 300_000_000,
            requiredFiles: [RemoteModelFile(path: "weights.safetensors", size: 300_000_000, sha256: "abc")],
            estimatedWeightMemory: 300_000_000,
            estimatedRuntimeMemory: 900_000_000,
            supportedRuntimes: [.mlx],
            contextLength: 32_768,
            metadata: ["license": "apache-2.0"]
        )
        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(ModelDescriptor.self, from: data)
        XCTAssertEqual(decoded, descriptor)
    }

    func testModalityCaseCount() {
        XCTAssertEqual(ModelModality.allCases.count, 13)
        XCTAssertEqual(ModelFormat.allCases.count, 6)
        XCTAssertEqual(RuntimeKind.allCases.count, 8)
    }
}

final class AIRequestTests: XCTestCase {
    private var model: ModelDescriptor {
        ModelDescriptor(repoID: "org/m", name: "m")
    }

    func testGenerationParametersDefaults() {
        let p = GenerationParameters()
        XCTAssertEqual(p.temperature, 0.7)
        XCTAssertEqual(p.maxTokens, 512)
        XCTAssertNil(p.seed)
    }

    func testJSONValueRoundTrip() throws {
        let value: JSONValue = .object([
            "key": .string("v"),
            "n": .number(42.5),
            "b": .bool(true),
            "arr": .array([.null, .number(1)]),
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testDecisionResultCodable() throws {
        let result = DecisionResult(key: "action", value: .string("open"))
        let data = try JSONEncoder().encode(result)
        XCTAssertEqual(try JSONDecoder().decode(DecisionResult.self, from: data), result)
    }

    func testChatInputCodable() throws {
        let input = AIInput.chat([
            .init(role: .system, content: "You are terse."),
            .init(role: .user, content: "Hi"),
        ])
        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(AIInput.self, from: data)
        XCTAssertEqual(decoded, input)
    }
}

final class LocallyErrorTests: XCTestCase {
    func testUserMessageAndDetail() {
        let err = LocallyError.insufficientStorage(
            userMessage: "Not enough space.",
            technicalDetail: "need 4 GB, have 2 GB"
        )
        XCTAssertEqual(err.userMessage, "Not enough space.")
        XCTAssertEqual(err.technicalDetail, "need 4 GB, have 2 GB")
    }

    func testPathTraversalHasSafeUserMessage() {
        let err = LocallyError.pathTraversal(technicalDetail: "../etc/passwd")
        XCTAssertFalse(err.userMessage.contains("passwd"))
        XCTAssertTrue(err.technicalDetail.contains("passwd"))
    }

    func testCancelled() {
        XCTAssertEqual(LocallyError.cancelled.userMessage, "The operation was cancelled.")
    }
}

final class LogTests: XCTestCase {
    func testAllCategoriesLogWithoutCrashing() {
        for category in Log.Category.allCases {
            Log.debug(category, "debug")
            Log.info(category, "info")
            Log.warning(category, "warn")
            Log.error(category, "error")
        }
        XCTAssertEqual(Log.Category.allCases.count, 11)
    }
}
