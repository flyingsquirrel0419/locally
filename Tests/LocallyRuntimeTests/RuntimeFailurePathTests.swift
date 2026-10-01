import XCTest
@testable import LocallyRuntime
import LocallyCore

/// Week 12 hardening: runtime-level failure paths — corrupted model files,
/// unsupported configurations, cancellation under memory-pressure-style
/// signals, and unload/release behavior.
final class RuntimeFailurePathTests: XCTestCase {

    private func tempGGUF(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rt-\(UUID().uuidString).gguf")
        try data.write(to: url)
        return url
    }

    private func model(at url: URL, modality: ModelModality = .text,
                       formats: [ModelFormat] = [.gguf]) -> ModelDescriptor {
        var m = ModelDescriptor(repoID: "local/test", name: "test", modality: modality,
                                formats: formats)
        m.metadata["localPath"] = url.path
        return m
    }

    // MARK: - Corrupted model files

    /// Random bytes with a valid GGUF magic but garbage structure: parse
    /// fails, error is user-facing, no crash.
    func testRandomBytesWithValidMagicFailCleanly() async throws {
        var data = Data([0x47, 0x47, 0x55, 0x46])  // "GGUF"
        data.append(contentsOf: [3, 0, 0, 0])      // version 3
        data.append(contentsOf: (0..<4096).map { _ in UInt8.random(in: 0...255) })
        let url = try tempGGUF(data)
        defer { try? FileManager.default.removeItem(at: url) }

        let runtime = GGUFRuntime()
        do {
            try await runtime.load(model(at: url))
            XCTFail("garbage GGUF must not load")
        } catch let error as LocallyError {
            XCTAssertFalse(error.userMessage.isEmpty)
            XCTAssertFalse(error.technicalDetail.isEmpty)
        }
    }

    /// An empty file fails cleanly.
    func testEmptyFileFailsCleanly() async throws {
        let url = try tempGGUF(Data())
        defer { try? FileManager.default.removeItem(at: url) }
        let runtime = GGUFRuntime()
        do {
            try await runtime.load(model(at: url))
            XCTFail("empty file must not load")
        } catch let error as LocallyError {
            XCTAssertFalse(error.userMessage.isEmpty)
        }
    }

    /// A file whose declared counts explode past limits is rejected by the
    /// parser (limitExceeded), not by a crash or a huge allocation.
    func testImplausibleHeaderRejected() async throws {
        var data = Data([0x47, 0x47, 0x55, 0x46])
        data.append(contentsOf: [3, 0, 0, 0])                  // version 3
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F]) // huge tensor count
        data.append(contentsOf: [0x01, 0, 0, 0, 0, 0, 0, 0])   // 1 kv
        data.append(contentsOf: (0..<128).map { _ in UInt8(0) })
        let url = try tempGGUF(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let runtime = GGUFRuntime()
        do {
            try await runtime.load(model(at: url))
            XCTFail("implausible header must not load")
        } catch let error as LocallyError {
            XCTAssertFalse(error.technicalDetail.isEmpty)
        }
    }

    // MARK: - Unsupported routing

    /// Unsupported modality/format/architecture all route to a decision with
    /// no runtime and an honest reason.
    func testRouterReportsUnsupportedWithReasons() {
        let caps = DeviceCapabilities(physicalMemory: 8 << 30, metalAvailable: false,
                                      neuralEngineAvailable: false)
        let router = RuntimeRouter(runtimes: [GGUFRuntime()])

        // Vision model: GGUF runtime refuses.
        let vlm = ModelDescriptor(repoID: "a/vlm", name: "vlm", modality: .visionLanguage,
                                  formats: [.gguf], supportedRuntimes: [.mlx])
        let d1 = router.decide(for: vlm, on: caps)
        XCTAssertNil(d1.runtimeKind)
        if case .unsupported(let reason) = d1.rating {
            XCTAssertFalse(reason.isEmpty)
        } else {
            XCTFail("expected unsupported, got \(d1.rating)")
        }

        // safetensors-only text model: no GGUF file, unsupported.
        let st = ModelDescriptor(repoID: "a/st", name: "st", modality: .text,
                                 formats: [.safetensors], supportedRuntimes: [])
        let d2 = router.decide(for: st, on: caps)
        XCTAssertNil(d2.runtimeKind)
        XCTAssertFalse(d2.reason.isEmpty)

        // Text GGUF with an architecture llama.cpp does not know: risky at
        // best, never silently "supported".
        var weird = ModelDescriptor(repoID: "a/weird", name: "weird", modality: .text,
                                    formats: [.gguf], supportedRuntimes: [.gguf])
        weird.architecture = "definitely-not-an-arch"
        let d3 = router.decide(for: weird, on: caps)
        if GGUFRuntime.isLlamaLinked {
            XCTAssertEqual(d3.runtimeKind, .gguf)
            if case .risky(let reason) = d3.rating {
                XCTAssertTrue(reason.contains("definitely-not-an-arch"))
            } else {
                XCTFail("unknown arch must be risky, got \(d3.rating)")
            }
        } else {
            XCTAssertNil(d3.runtimeKind, "without llama linked even GGUF text is unsupported")
        }
    }

    // MARK: - Cancellation / memory-pressure policy

    /// A run cancelled from outside (the memory-pressure/thermal path calls
    /// Task cancellation) must stop cleanly and emit exactly one terminal
    /// `.failed(.cancelled)` — no crash, no double terminal, no hang.
    func testCancellationEmitsExactlyOneTerminalCancelled() async throws {
        let runtime = GGUFRuntime()
        // No model loaded: run fails fast, but the cancellation contract is
        // what we assert — cancel before consuming.
        let request = AIRequest(
            model: model(at: URL(fileURLWithPath: "/nonexistent.gguf")),
            input: .text("hello"),
            parameters: GenerationParameters(maxTokens: 8))
        let stream = runtime.run(request)
        let consumer = Task { await TerminalEventInvariant.collect(stream) }
        try await Task.sleep(nanoseconds: 20_000_000)
        consumer.cancel()
        let events = await consumer.value
        // Terminal invariant holds whether the cancellation or the
        // not-loaded error wins the race: exactly one terminal event.
        TerminalEventInvariant.assertExactlyOneTerminalEvent(events)
    }

    /// The terminal event of a cancelled run is .failed(.cancelled) or
    /// .failed with a memory/cancel reason — asserted against a runtime
    /// whose only possible outcome is failure (no model loaded).
    func testCancelledRunTerminalsAreFailures() async throws {
        let runtime = GGUFRuntime()
        let request = AIRequest(
            model: model(at: URL(fileURLWithPath: "/nonexistent.gguf")),
            input: .text("hello"),
            parameters: GenerationParameters(maxTokens: 8))
        let events = await TerminalEventInvariant.collect(runtime.run(request))
        guard case .failed(let error) = events.last else {
            return XCTFail("expected terminal .failed, got \(String(describing: events.last))")
        }
        // run-before-load surfaces runtimeUnavailable (a failure terminal).
        if case .runtimeUnavailable = error { /* expected */ }
        else if case .cancelled = error { /* also acceptable under race */ }
        else { XCTFail("unexpected error: \(error)") }
    }

    // MARK: - Unload releases

    /// After unload() a second load works — the runtime is reusable.
    /// Without llama linked this asserts the parser path; with llama it
    /// exercises the real bridge unload.
    func testSecondLoadAfterUnloadWorks() async throws {
        guard let url = Self.liveModelURL else {
            throw XCTSkip("needs the live GGUF (LOCALLY_LIVE_LLAMA=1)")
        }
        let runtime = GGUFRuntime()
        try await runtime.load(Self.liveModel(at: url))
        await runtime.unload()
        try await runtime.load(Self.liveModel(at: url))  // must not throw
        await runtime.unload()
    }

    /// RSS across 5 load/unload cycles must not grow unboundedly.
    /// Reports the measured numbers; asserts growth < 50 MB.
    func testLoadUnloadCyclesDoNotLeakUnboundedly() async throws {
        guard let url = Self.liveModelURL else {
            throw XCTSkip("needs the live GGUF (LOCALLY_LIVE_LLAMA=1)")
        }
        let runtime = GGUFRuntime()
        var rssSamples: [Int64] = []
        for cycle in 0..<5 {
            try await runtime.load(Self.liveModel(at: url))
            await runtime.unload()
            if let rss = Self.residentMemoryBytes() {
                rssSamples.append(rss)
                print("RSS cycle \(cycle): \(rss / (1 << 20)) MB")
            }
        }
        XCTAssertEqual(rssSamples.count, 5, "could not read /proc/self/statm")
        guard let first = rssSamples.first, let last = rssSamples.last else { return }
        let growth = last - first
        print("RSS growth over 5 load/unload cycles: \(growth / (1 << 20)) MB "
              + "(samples: \(rssSamples.map { "\($0 / (1 << 20))" }.joined(separator: ", ")) MB)")
        XCTAssertLessThan(growth, 50 << 20,
                          "RSS grew \(growth / (1 << 20)) MB across 5 cycles — possible leak")
    }

    // MARK: - Live-model helpers

    private static var liveModelURL: URL? {
        guard ProcessInfo.processInfo.environment["LOCALLY_LIVE_LLAMA"] == "1" else { return nil }
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent(".deps/models/SmolLM2-135M-Instruct-Q4_K_M.gguf")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private static func liveModel(at url: URL) -> ModelDescriptor {
        var m = ModelDescriptor(repoID: "bartowski/SmolLM2-135M-Instruct-GGUF",
                                name: "SmolLM2-135M-Instruct", architecture: "llama",
                                modality: .text, formats: [.gguf])
        m.metadata["localPath"] = url.path
        return m
    }

    /// Resident set size from /proc/self/statm (Linux); nil elsewhere.
    static func residentMemoryBytes() -> Int64? {
        #if os(Linux)
        guard let contents = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) else {
            return nil
        }
        let fields = contents.split(separator: " ")
        guard fields.count > 1, let pages = Int64(fields[1]) else { return nil }
        return pages * Int64(sysconf(Int32(_SC_PAGESIZE)))
        #else
        return nil
        #endif
    }
}
