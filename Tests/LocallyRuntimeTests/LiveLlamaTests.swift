import XCTest
@testable import LocallyRuntime
import LocallyCore

/// Real end-to-end inference against llama.cpp with a downloaded GGUF.
/// Gated on LOCALLY_LIVE_LLAMA=1; the model is fetched by
/// scripts/download-test-model.sh into .deps/models. Never runs in CI.
final class LiveLlamaTests: XCTestCase {

    private var liveModelURL: URL? {
        guard ProcessInfo.processInfo.environment["LOCALLY_LIVE_LLAMA"] == "1" else { return nil }
        // Walk up from the test file until we find .deps/models.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent(".deps/models/SmolLM2-135M-Instruct-Q4_K_M.gguf")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private func liveModel(at url: URL) -> ModelDescriptor {
        var m = ModelDescriptor(repoID: "bartowski/SmolLM2-135M-Instruct-GGUF",
                                name: "SmolLM2-135M-Instruct", architecture: "llama",
                                modality: .text, formats: [.gguf])
        m.metadata["localPath"] = url.path
        return m
    }

    func testRealInferenceProducesCoherentOutput() async throws {
        guard let url = liveModelURL else {
            throw XCTSkip("LOCALLY_LIVE_LLAMA not set or model missing")
        }
        let runtime = GGUFRuntime()
        try await runtime.load(liveModel(at: url))
        defer { Task { await runtime.unload() } }

        let request = AIRequest(
            model: liveModel(at: url),
            input: .chat([.init(role: .user, content: "What is the capital of France? Answer with one word.")]),
            parameters: GenerationParameters(temperature: 0, topP: 1.0, maxTokens: 32))
        var streamed = ""
        var result: AIResult?
        for try await event in runtime.run(request) {
            switch event {
            case .token(let t): streamed += t
            case .completed(let r): result = r
            case .failed(let e): XCTFail("inference failed: \(e.technicalDetail)")
            default: break
            }
        }
        let output = result?.text ?? streamed
        XCTAssertFalse(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertNotNil(result?.metadata.tokensPerSecond)
        XCTAssertGreaterThan(result?.metadata.tokensPerSecond ?? 0, 0)
        XCTAssertNotNil(result?.metadata.ttft)
        XCTAssertGreaterThan(result?.metadata.generatedTokens ?? 0, 0)
        print("LIVE OUTPUT >>> \(output)")
        print("LIVE METADATA >>> \(String(describing: result?.metadata))")
    }

    func testCorruptedModelFileFailsNotCrashes() async throws {
        guard let url = liveModelURL else {
            throw XCTSkip("LOCALLY_LIVE_LLAMA not set or model missing")
        }
        // Copy + truncate to half.
        let corrupted = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupted-\(UUID().uuidString).gguf")
        try FileManager.default.copyItem(at: url, to: corrupted)
        defer { try? FileManager.default.removeItem(at: corrupted) }
        let handle = try FileHandle(forWritingTo: corrupted)
        let size = try handle.seekToEnd()
        try handle.truncate(atOffset: size / 2)
        try handle.close()

        let runtime = GGUFRuntime()
        // Header parses (it's intact); llama load should fail gracefully or
        // (if llama tolerates truncation) generation must fail, never crash.
        do {
            try await runtime.load(liveModel(at: corrupted))
            let request = AIRequest(
                model: liveModel(at: corrupted),
                input: .text("hi"),
                parameters: GenerationParameters(maxTokens: 4))
            for try await event in runtime.run(request) {
                if case .failed = event { break }
            }
        } catch is LocallyError {
            // expected path
        }
        await runtime.unload()
    }

    func testCancellationStopsStream() async throws {
        guard let url = liveModelURL else {
            throw XCTSkip("LOCALLY_LIVE_LLAMA not set or model missing")
        }
        let runtime = GGUFRuntime()
        try await runtime.load(liveModel(at: url))
        defer { Task { await runtime.unload() } }

        let request = AIRequest(
            model: liveModel(at: url),
            input: .text("Write a very long story about a dragon."),
            parameters: GenerationParameters(temperature: 0.9, maxTokens: 512))
        let stream = runtime.run(request)
        let consumer = Task { () -> (Int, Bool) in
            var tokens = 0
            var cancelled = false
            do {
                for try await event in stream {
                    if case .token = event { tokens += 1 }
                    if case .failed(let e) = event, case .cancelled = e { cancelled = true }
                }
            } catch {
                cancelled = true
            }
            return (tokens, cancelled)
        }
        try await Task.sleep(for: .milliseconds(800))
        consumer.cancel()
        let (tokens, _) = await consumer.value
        // We cancelled mid-stream; must not have produced the full 512 tokens.
        XCTAssertLessThan(tokens, 512)
    }
}
