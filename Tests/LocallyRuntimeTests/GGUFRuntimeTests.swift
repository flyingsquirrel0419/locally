import XCTest
@testable import LocallyRuntime
import LocallyCore

final class GGUFRuntimeTests: XCTestCase {

    private func tempGGUF(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gguf-runtime-\(UUID().uuidString).gguf")
        try data.write(to: url)
        return url
    }

    private func model(at url: URL) -> ModelDescriptor {
        var m = ModelDescriptor(repoID: "local/test", name: "test", modality: .text,
                                formats: [.gguf])
        m.metadata["localPath"] = url.path
        return m
    }

    func testLoadCorruptedFileFailsWithErrorNotCrash() async throws {
        var garbage = Data([0xDE, 0xAD, 0xBE, 0xEF])
        garbage.append(contentsOf: [UInt8](repeating: 0, count: 100))
        let url = try tempGGUF(garbage)
        defer { try? FileManager.default.removeItem(at: url) }

        let runtime = GGUFRuntime()
        do {
            try await runtime.load(model(at: url))
            XCTFail("expected load to throw")
        } catch let error as LocallyError {
            XCTAssertFalse(error.userMessage.isEmpty)
        }
    }

    func testLoadTruncatedGGUFFailsWithErrorNotCrash() async throws {
        var valid = Data()
        valid.append(contentsOf: [0x47, 0x47, 0x55, 0x46]) // "GGUF"
        valid.append(contentsOf: [3, 0, 0, 0])              // version 3
        valid.append(contentsOf: [0xFF, 0xFF])              // truncated counts
        let url = try tempGGUF(valid)
        defer { try? FileManager.default.removeItem(at: url) }

        let runtime = GGUFRuntime()
        do {
            try await runtime.load(model(at: url))
            XCTFail("expected load to throw")
        } catch let error as LocallyError {
            XCTAssertFalse(error.userMessage.isEmpty)
        }
    }

    func testLoadMissingFileFails() async {
        let runtime = GGUFRuntime()
        var m = ModelDescriptor(repoID: "local/test", name: "test", modality: .text,
                                formats: [.gguf])
        m.metadata["localPath"] = "/nonexistent/\(UUID().uuidString).gguf"
        do {
            try await runtime.load(m)
            XCTFail("expected load to throw")
        } catch {
            // any LocallyError is fine
        }
    }

    func testRunWithoutLoadFails() async throws {
        let runtime = GGUFRuntime()
        let request = AIRequest(
            model: ModelDescriptor(repoID: "a/b", name: "b", modality: .text,
                                   formats: [.gguf]),
            input: .text("hello"))
        let events = await TerminalEventInvariant.assertStream(runtime.run(request))
        guard case .failed = events.last else {
            return XCTFail("expected terminal .failed, got \(events)")
        }
    }
}
