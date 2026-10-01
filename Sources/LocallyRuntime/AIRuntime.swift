import Foundation
import LocallyCore

/// Execution backend for a model. Concrete runtimes (MLX, GGUF, CoreML,
/// decision, vision, diffusion, audio, video) land in later weeks.
public protocol AIRuntime: Sendable {
    var kind: RuntimeKind { get }
    /// Honest capability probe: false means this runtime cannot run on the
    /// current device/build (e.g. MLX on a simulator or Linux).
    func isSupported(on device: DeviceCapabilities) -> Bool
    func load(_ model: ModelDescriptor) async throws
    func unload() async
    func run(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error>
}

/// Minimal device capability surface the runtime layer needs; keeps
/// LocallyRuntime decoupled from LocallyDevice.
public struct DeviceCapabilities: Sendable, Hashable {
    public var physicalMemory: UInt64
    public var metalAvailable: Bool
    public var neuralEngineAvailable: Bool

    public init(physicalMemory: UInt64, metalAvailable: Bool, neuralEngineAvailable: Bool) {
        self.physicalMemory = physicalMemory
        self.metalAvailable = metalAvailable
        self.neuralEngineAvailable = neuralEngineAvailable
    }
}

/// Runtime that honestly reports it cannot run anything yet.
public struct UnsupportedRuntime: AIRuntime {
    public let kind: RuntimeKind
    private let reason: String

    public init(kind: RuntimeKind, reason: String) {
        self.kind = kind
        self.reason = reason
    }

    public func isSupported(on device: DeviceCapabilities) -> Bool { false }

    public func load(_ model: ModelDescriptor) async throws {
        throw LocallyError.runtimeUnavailable(
            userMessage: "This runtime isn't available for \(model.name) yet.",
            technicalDetail: reason
        )
    }

    public func unload() async {}

    public func run(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.failed(.runtimeUnavailable(
                userMessage: "This runtime isn't available for \(request.model.name) yet.",
                technicalDetail: reason
            )))
            continuation.finish()
        }
    }
}
