import XCTest
@testable import LocallyRuntime
import LocallyCore

final class GGUFParserTests: XCTestCase {

    /// Minimal GGUF v3 writer for fixtures.
    struct Builder {
        var data = Data()

        mutating func u8(_ v: UInt8) { data.append(v) }
        mutating func u16(_ v: UInt16) { var v = v.littleEndian; data.append(contentsOf: withUnsafeBytes(of: &v) { Array($0) }) }
        mutating func u32(_ v: UInt32) { var v = v.littleEndian; data.append(contentsOf: withUnsafeBytes(of: &v) { Array($0) }) }
        mutating func u64(_ v: UInt64) { var v = v.littleEndian; data.append(contentsOf: withUnsafeBytes(of: &v) { Array($0) }) }
        mutating func f32(_ v: Float) { var v = v.bitPattern.littleEndian; data.append(contentsOf: withUnsafeBytes(of: &v) { Array($0) }) }
        mutating func string(_ s: String) {
            let bytes = Array(s.utf8)
            u64(UInt64(bytes.count))
            data.append(contentsOf: bytes)
        }
        mutating func header(version: UInt32 = 3, tensors: UInt64, kv: UInt64) {
            u32(0x4655_4747) // "GGUF"
            u32(version)
            u64(tensors)
            u64(kv)
        }
    }

    private func validFile() -> Data {
        var b = Builder()
        b.header(version: 3, tensors: 2, kv: 7)
        b.string("general.architecture"); b.u32(8); b.string("llama")
        b.string("general.name"); b.u32(8); b.string("TestModel")
        b.string("llama.context_length"); b.u32(4); b.u32(2048)
        b.string("llama.block_count"); b.u32(4); b.u32(24)
        b.string("llama.embedding_length"); b.u32(4); b.u32(1024)
        b.string("llama.attention.head_count"); b.u32(4); b.u32(16)
        b.string("tokenizer.ggml.tokens"); b.u32(9); b.u32(8); b.u64(2)
        b.string("hello"); b.string("world")
        // tensor 0: token_embd.weight [1024, 100] F32
        b.string("token_embd.weight"); b.u32(2); b.u64(1024); b.u64(100); b.u32(0); b.u64(0)
        // tensor 1: blk.0.attn_q.weight [64, 1024] Q4_K (type 12)
        b.string("blk.0.attn_q.weight"); b.u32(2); b.u64(64); b.u64(1024); b.u32(12); b.u64(4096)
        return b.data
    }

    func testParsesValidHeader() throws {
        let header = try GGUFParser().parse(validFile())
        XCTAssertEqual(header.version, 3)
        XCTAssertEqual(header.tensorCount, 2)
        XCTAssertEqual(header.string("general.architecture"), "llama")
        XCTAssertEqual(header.string("general.name"), "TestModel")
        XCTAssertEqual(header.int("llama.context_length"), 2048)
        XCTAssertEqual(header.int("llama.block_count"), 24)
        XCTAssertEqual(header.int("llama.embedding_length"), 1024)
        XCTAssertEqual(header.int("llama.attention.head_count"), 16)
        if case .array(let tokens)? = header.metadata["tokenizer.ggml.tokens"] {
            XCTAssertEqual(tokens, [.string("hello"), .string("world")])
        } else {
            XCTFail("tokens array missing: \(header.metadata.keys)")
        }
        XCTAssertEqual(header.tensors.count, 2)
        XCTAssertEqual(header.tensors[0].name, "token_embd.weight")
        XCTAssertEqual(header.tensors[0].dimensions, [1024, 100])
        XCTAssertEqual(header.tensors[0].typeName, "F32")
        XCTAssertEqual(header.tensors[0].offset, 0)
        XCTAssertEqual(header.tensors[1].typeName, "Q4_K")
        XCTAssertEqual(header.alignment, 32)
    }

    func testParsesVersion2() throws {
        var b = Builder()
        b.header(version: 2, tensors: 0, kv: 1)
        b.string("general.architecture"); b.u32(8); b.string("gemma2")
        let header = try GGUFParser().parse(b.data)
        XCTAssertEqual(header.version, 2)
        XCTAssertEqual(header.string("general.architecture"), "gemma2")
    }

    func testParsesAllScalarTypes() throws {
        var b = Builder()
        b.header(version: 3, tensors: 0, kv: 10)
        b.string("u8"); b.u32(0); b.u8(200)
        b.string("i8"); b.u32(1); b.u8(0xFE)
        b.string("u16"); b.u32(2); b.u16(60_000)
        b.string("i16"); b.u32(3); b.u16(0xFFFE)
        b.string("u32"); b.u32(4); b.u32(3_000_000_000)
        b.string("i32"); b.u32(5); b.u32(0xFFFF_FFFE)
        b.string("f32"); b.u32(6); b.f32(1.5)
        b.string("bool"); b.u32(7); b.u8(1)
        b.string("u64"); b.u32(10); b.u64(18_000_000_000_000_000_000)
        b.string("i64"); b.u32(11); b.u64(0xFFFF_FFFF_FFFF_FFFE)
        let h = try GGUFParser().parse(b.data)
        XCTAssertEqual(h.metadata["u8"], .uint8(200))
        XCTAssertEqual(h.metadata["i8"], .int8(-2))
        XCTAssertEqual(h.metadata["u16"], .uint16(60_000))
        XCTAssertEqual(h.metadata["i16"], .int16(-2))
        XCTAssertEqual(h.metadata["u32"], .uint32(3_000_000_000))
        XCTAssertEqual(h.metadata["i32"], .int32(-2))
        XCTAssertEqual(h.metadata["f32"], .float32(1.5))
        XCTAssertEqual(h.metadata["bool"], .bool(true))
        XCTAssertEqual(h.metadata["u64"], .uint64(18_000_000_000_000_000_000))
        XCTAssertEqual(h.metadata["i64"], .int64(-2))
    }

    func testTruncatedAtEveryPrefixNeverCrashes() {
        let full = validFile()
        for length in 0..<full.count {
            let truncated = full.prefix(length)
            do {
                _ = try GGUFParser().parse(Data(truncated))
            } catch let error as GGUFParser.ParseError {
                // Any parse error is fine; a crash would fail the test run.
                _ = error
            } catch {
                XCTFail("unexpected error type at prefix \(length): \(error)")
            }
        }
    }

    func testBadMagic() {
        var b = Builder()
        b.u32(0xDEADBEEF); b.u32(3); b.u64(0); b.u64(0)
        XCTAssertThrowsError(try GGUFParser().parse(b.data)) { error in
            XCTAssertEqual(error as? GGUFParser.ParseError, .badMagic)
        }
    }

    func testUnsupportedVersion() {
        var b = Builder()
        b.header(version: 1, tensors: 0, kv: 0)
        XCTAssertThrowsError(try GGUFParser().parse(b.data)) { error in
            XCTAssertEqual(error as? GGUFParser.ParseError, .unsupportedVersion(1))
        }
    }

    func testHugeCountsRejected() {
        var b = Builder()
        b.header(version: 3, tensors: UInt64.max, kv: 0)
        XCTAssertThrowsError(try GGUFParser().parse(b.data)) { error in
            guard case .limitExceeded = error as? GGUFParser.ParseError else {
                return XCTFail("expected limitExceeded, got \(error)")
            }
        }
    }

    func testHugeStringLengthRejected() {
        var b = Builder()
        b.header(version: 3, tensors: 0, kv: 1)
        b.u64(UInt64(GGUFParser.Limits.maxStringLength) + 1) // string length without payload
        XCTAssertThrowsError(try GGUFParser().parse(b.data)) { error in
            guard case .limitExceeded = error as? GGUFParser.ParseError else {
                return XCTFail("expected limitExceeded, got \(error)")
            }
        }
    }

    func testHugeArrayCountRejectedFast() {
        var b = Builder()
        b.header(version: 3, tensors: 0, kv: 1)
        b.string("tokenizer.ggml.tokens")
        b.u32(9); b.u32(8); b.u64(5_000_000_000) // array of strings, absurd count
        XCTAssertThrowsError(try GGUFParser().parse(b.data)) { error in
            let e = error as? GGUFParser.ParseError
            guard case .limitExceeded = e ?? .truncated else {
                return XCTFail("expected limitExceeded or truncated, got \(error)")
            }
        }
    }

    func testWrongTypeTagRejected() {
        var b = Builder()
        b.header(version: 3, tensors: 0, kv: 1)
        b.string("general.name"); b.u32(99); b.u8(0)
        XCTAssertThrowsError(try GGUFParser().parse(b.data)) { error in
            guard case .invalidValue = error as? GGUFParser.ParseError else {
                return XCTFail("expected invalidValue, got \(error)")
            }
        }
    }

    func testBoolValueOutOfRangeRejected() {
        var b = Builder()
        b.header(version: 3, tensors: 0, kv: 1)
        b.string("k"); b.u32(7); b.u8(2)
        XCTAssertThrowsError(try GGUFParser().parse(b.data)) { error in
            guard case .invalidValue = error as? GGUFParser.ParseError else {
                return XCTFail("expected invalidValue, got \(error)")
            }
        }
    }

    func testNestedArrayRejected() {
        var b = Builder()
        b.header(version: 3, tensors: 0, kv: 1)
        b.string("k"); b.u32(9); b.u32(9); b.u64(0)
        XCTAssertThrowsError(try GGUFParser().parse(b.data)) { error in
            guard case .invalidValue = error as? GGUFParser.ParseError else {
                return XCTFail("expected invalidValue, got \(error)")
            }
        }
    }

    func testSummaryExtraction() throws {
        let summary = GGUFModelSummary(header: try GGUFParser().parse(validFile()))
        XCTAssertEqual(summary.architecture, "llama")
        XCTAssertEqual(summary.name, "TestModel")
        XCTAssertEqual(summary.contextLength, 2048)
        XCTAssertEqual(summary.blockCount, 24)
        XCTAssertEqual(summary.embeddingLength, 1024)
        XCTAssertEqual(summary.headCount, 16)
        XCTAssertEqual(summary.parameterCount, 1024 * 100 + 64 * 1024)
        XCTAssertNil(summary.quantization)
    }

    func testSummaryFileTypeMapping() {
        var b = Builder()
        b.header(version: 3, tensors: 0, kv: 1)
        b.string("general.file_type"); b.u32(4); b.u32(15) // MOSTLY_Q4_K_M
        let summary = GGUFModelSummary(header: try! GGUFParser().parse(b.data))
        XCTAssertEqual(summary.quantization?.scheme, "Q4_K_M")
        XCTAssertEqual(summary.quantization?.bits, 4)
    }

    func testParseFromFileHandle() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gguf-test-\(UUID().uuidString).gguf")
        try validFile().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let header = try GGUFParser().parse(fileAt: url)
        XCTAssertEqual(header.string("general.name"), "TestModel")
    }

    func testAlignmentOverride() throws {
        var b = Builder()
        b.header(version: 3, tensors: 0, kv: 1)
        b.string("general.alignment"); b.u32(4); b.u32(64)
        let header = try GGUFParser().parse(b.data)
        XCTAssertEqual(header.alignment, 64)
    }
}
