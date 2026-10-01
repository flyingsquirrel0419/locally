import XCTest
@testable import LocallyRuntime
import LocallyCore

final class RuntimeRouterTests: XCTestCase {
    private var device: DeviceCapabilities {
        DeviceCapabilities(physicalMemory: 8_000_000_000, metalAvailable: false,
                           neuralEngineAvailable: false)
    }

    private struct StubRuntime: ModelCompatibleRuntime {
        let kind: RuntimeKind
        let rating: CompatibilityRating
        func compatibility(with model: ModelDescriptor, on device: DeviceCapabilities) -> CompatibilityRating { rating }
        func isSupported(on device: DeviceCapabilities) -> Bool { true }
        func load(_ model: ModelDescriptor) async throws {}
        func unload() async {}
        func run(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    func testPrefersSupportedOverRisky() {
        let router = RuntimeRouter(runtimes: [
            StubRuntime(kind: .gguf, rating: .risky(reason: "unknown arch")),
            StubRuntime(kind: .mlx, rating: .supported),
        ])
        let decision = router.decide(for: ModelDescriptor(repoID: "a/b", name: "b"), on: device)
        XCTAssertEqual(decision.runtimeKind, .mlx)
        XCTAssertTrue(decision.isRunnable)
    }

    func testAllUnsupportedReturnsReason() {
        let router = RuntimeRouter(runtimes: [
            StubRuntime(kind: .gguf, rating: .unsupported(reason: "no llama")),
            StubRuntime(kind: .mlx, rating: .unsupported(reason: "no metal")),
        ])
        let decision = router.decide(for: ModelDescriptor(repoID: "a/b", name: "b"), on: device)
        XCTAssertNil(decision.runtimeKind)
        XCTAssertFalse(decision.isRunnable)
        XCTAssertTrue(decision.reason.contains("no llama"))
        XCTAssertTrue(decision.reason.contains("no metal"))
    }

    func testEmptyRouterIsHonest() {
        let router = RuntimeRouter(runtimes: [])
        let decision = router.decide(for: ModelDescriptor(repoID: "a/b", name: "b"), on: device)
        XCTAssertNil(decision.runtimeKind)
        XCTAssertEqual(decision.reason, "no runtimes registered")
    }

    func testGGUFRuntimeCompatibilityWithoutLlama() {
        let runtime = GGUFRuntime()
        let textGGUF = ModelDescriptor(repoID: "a/b", name: "b", architecture: "llama",
                                       modality: .text, formats: [.gguf])
        let rating = runtime.compatibility(with: textGGUF, on: device)
        if GGUFRuntime.isLlamaLinked {
            XCTAssertEqual(rating, .supported)
        } else {
            guard case .unsupported(let reason) = rating else {
                return XCTFail("expected unsupported without llama, got \(rating)")
            }
            XCTAssertTrue(reason.contains("not linked"))
        }
    }

    func testGGUFRuntimeRejectsNonText() {
        let runtime = GGUFRuntime()
        let vision = ModelDescriptor(repoID: "a/b", name: "b", modality: .imageGeneration,
                                     formats: [.gguf])
        guard case .unsupported = runtime.compatibility(with: vision, on: device) else {
            return XCTFail("expected unsupported for imageGeneration")
        }
    }

    func testGGUFRuntimeRejectsNonGGUFFormat() {
        let runtime = GGUFRuntime()
        let model = ModelDescriptor(repoID: "a/b", name: "b", modality: .text,
                                    formats: [.safetensors])
        guard case .unsupported = runtime.compatibility(with: model, on: device) else {
            return XCTFail("expected unsupported for safetensors-only")
        }
    }

    func testUnknownArchitectureIsRiskyWhenLinked() {
        let runtime = GGUFRuntime()
        let model = ModelDescriptor(repoID: "a/b", name: "b", architecture: "madeup-arch",
                                    modality: .text, formats: [.gguf])
        let rating = runtime.compatibility(with: model, on: device)
        if GGUFRuntime.isLlamaLinked {
            guard case .risky = rating else { return XCTFail("expected risky, got \(rating)") }
        } else {
            guard case .unsupported = rating else { return XCTFail("expected unsupported") }
        }
    }
}
