import XCTest
@testable import LocallyStorage

final class StreamingSHA256Tests: XCTestCase {
    private func hash(_ string: String) -> String {
        var h = StreamingSHA256()
        h.update(Data(string.utf8))
        return h.finalize()
    }

    func testEmptyString() {
        XCTAssertEqual(hash(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testABC() {
        XCTAssertEqual(hash("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testLongerThanOneBlock() {
        // 56+ byte input exercises padding across block boundary.
        let input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        XCTAssertEqual(hash(input), "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testChunkedUpdatesMatchSingleUpdate() {
        let data = Data((0..<65_536).map { UInt8($0 % 251) })  // 64 KB pattern
        var single = StreamingSHA256()
        single.update(data)
        var chunked = StreamingSHA256()
        for offset in stride(from: 0, to: data.count, by: 1_000) {
            let end = min(offset + 1_000, data.count)
            chunked.update(data.subdata(in: offset..<end))
        }
        XCTAssertEqual(single.finalize(), chunked.finalize())
    }

    func testOneMegabytePatternMatchesReference() throws {
        // Reference digest computed with sha256sum on Linux; guards the pure
        // Swift fallback against drift from CryptoKit behavior.
        let pattern = Data((0..<(1 << 20)).map { UInt8($0 % 256) })
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sha256-pattern-\(UUID().uuidString).bin")
        try pattern.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let digest = try DownloadManager.sha256Hex(of: tmp)
        // Reference digest from `sha256sum` on the same 1 MB pattern.
        XCTAssertEqual(digest, "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83")
        var hasher = StreamingSHA256()
        hasher.update(pattern)
        XCTAssertEqual(digest, hasher.finalize())
    }
}
