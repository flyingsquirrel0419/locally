import XCTest
@testable import LocallyRuntime
import LocallyCore

/// GenerationPacer contract: the GGUF decode loop awaits the pacer once per
/// generated token, and the no-op default adds no measurable delay.
final class GenerationPacerTests: XCTestCase {

    /// Counting fake pacer for the live llama test.
    final class CountingPacer: GenerationPacer, @unchecked Sendable {
        private let counter = LockedState(0)
        var calls: Int { counter.withLock { $0 } }
        func pace() async {
            counter.withLock { $0 += 1 }
        }
    }

    private var liveModelURL: URL? {
        guard ProcessInfo.processInfo.environment["LOCALLY_LIVE_LLAMA"] == "1" else { return nil }
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent(
                ".deps/models/SmolLM2-135M-Instruct-Q4_K_M.gguf")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// The decode loop must call pace() once per generated token (live-gated:
    /// needs llama + the test model).
    func testGGUFLooPacesPerToken() async throws {
        guard let url = liveModelURL else {
            throw XCTSkip("LOCALLY_LIVE_LLAMA not set or model missing")
        }
        var m = ModelDescriptor(repoID: "local/test", name: "test",
                                architecture: "llama", modality: .text, formats: [.gguf])
        m.metadata["localPath"] = url.path

        let pacer = CountingPacer()
        let runtime = GGUFRuntime(pacer: pacer)
        try await runtime.load(m)
        defer { Task { await runtime.unload() } }

        let request = AIRequest(
            model: m,
            input: .text("Hello"),
            parameters: GenerationParameters(temperature: 0, topP: 1.0, maxTokens: 8))
        var generatedTokens = 0
        for try await event in runtime.run(request) {
            if case .completed(let result) = event {
                generatedTokens = result.metadata.generatedTokens ?? 0
            }
        }
        XCTAssertGreaterThan(generatedTokens, 0)
        XCTAssertEqual(pacer.calls, generatedTokens,
                       "pacer must be awaited exactly once per generated token")
    }

    /// No-op pacer returns immediately: pacing 1000 tokens must take no more
    /// than a trivial wall-clock budget.
    func testNoOpPacerAddsNoOverhead() async throws {
        let pacer = NoOpGenerationPacer()
        let start = ContinuousClock.now
        for _ in 0..<1000 {
            await pacer.pace()
        }
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed.components.seconds, 1,
                          "no-op pacer took \(elapsed) for 1000 calls")
    }

    /// Zero-delay fixed pacer must not sleep either.
    func testFixedDelayPacerWithZeroDelaySkipsSleep() async throws {
        let pacer = FixedDelayGenerationPacer(delayNanoseconds: 0)
        let start = ContinuousClock.now
        for _ in 0..<1000 {
            await pacer.pace()
        }
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed.components.seconds, 1)
    }

    /// A positive fixed delay actually delays.
    func testFixedDelayPacerSleeps() async throws {
        let pacer = FixedDelayGenerationPacer(delayNanoseconds: 5_000_000) // 5 ms
        let start = ContinuousClock.now
        for _ in 0..<10 {
            await pacer.pace()
        }
        let elapsed = ContinuousClock.now - start
        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        XCTAssertGreaterThanOrEqual(ms, 40, "10 x 5ms sleeps should take ~50ms, took \(ms)ms")
    }
}
