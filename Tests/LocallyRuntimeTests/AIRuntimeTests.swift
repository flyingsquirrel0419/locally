import XCTest
@testable import LocallyRuntime
import LocallyCore

final class UnsupportedRuntimeTests: XCTestCase {
    private var model: ModelDescriptor {
        ModelDescriptor(repoID: "org/m", name: "m")
    }

    private var device: DeviceCapabilities {
        DeviceCapabilities(physicalMemory: 8_000_000_000, metalAvailable: false,
                           neuralEngineAvailable: false)
    }

    func testReportsUnsupported() {
        let runtime = UnsupportedRuntime(kind: .mlx, reason: "not built")
        XCTAssertFalse(runtime.isSupported(on: device))
    }

    func testLoadThrowsRuntimeUnavailable() async {
        let runtime = UnsupportedRuntime(kind: .gguf, reason: "not built")
        do {
            try await runtime.load(model)
            XCTFail("expected throw")
        } catch let error as LocallyError {
            guard case .runtimeUnavailable = error else {
                return XCTFail("wrong error: \(error)")
            }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testRunYieldsFailureEvent() async throws {
        let runtime = UnsupportedRuntime(kind: .coreml, reason: "not built")
        let request = AIRequest(model: model, input: .text("hi"))
        let events = await TerminalEventInvariant.assertStream(runtime.run(request))
        XCTAssertEqual(events.count, 1)
        guard case .failed(let error) = events.first,
              case .runtimeUnavailable = error else {
            return XCTFail("expected failed(runtimeUnavailable), got \(events)")
        }
    }
}
