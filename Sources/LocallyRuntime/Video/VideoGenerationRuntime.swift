import Foundation
import LocallyCore

/// Parameters for text-to-video generation. The interface is defined now so
/// a real runtime can slot in later without changing call sites.
public struct VideoGenerationParameters: Codable, Sendable, Hashable {
    /// Seconds of video to synthesize.
    public var duration: TimeInterval
    public var framesPerSecond: Int
    public var width: Int
    public var height: Int

    public init(duration: TimeInterval = 2.0, framesPerSecond: Int = 8,
                width: Int = 512, height: Int = 512) {
        self.duration = duration
        self.framesPerSecond = framesPerSecond
        self.width = width
        self.height = height
    }
}

/// Runtime interface for text-to-video models.
public protocol VideoGeneratingRuntime: AIRuntime {
    func generateVideo(prompt: String,
                       parameters: VideoGenerationParameters,
                       request: AIRequest) -> AsyncThrowingStream<AIEvent, Error>
}

/// Honest placeholder: no text-to-video model currently fits an iPhone's
/// memory and compute envelope in a shippable way. Reports unsupported with
/// a real reason instead of faking output.
public struct ExperimentalVideoGenerationRuntime: VideoGeneratingRuntime {
    public let kind: RuntimeKind = .video

    public static let unavailableReason =
        "Video generation is experimental and not available on iPhone yet — no text-to-video model fits the on-device memory and compute budget today."

    public init() {}

    public func isSupported(on device: DeviceCapabilities) -> Bool { false }

    public func load(_ model: ModelDescriptor) async throws {
        throw LocallyError.unsupportedModality(
            userMessage: "Video generation is experimental and not available on iPhone yet.",
            technicalDetail: Self.unavailableReason)
    }

    public func unload() async {}

    public func run(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.failed(.unsupportedModality(
                userMessage: "Video generation is experimental and not available on iPhone yet.",
                technicalDetail: Self.unavailableReason)))
            continuation.finish()
        }
    }

    public func generateVideo(prompt: String,
                              parameters: VideoGenerationParameters,
                              request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
        run(request)
    }
}

extension ExperimentalVideoGenerationRuntime: ModelCompatibleRuntime {
    public func compatibility(with model: ModelDescriptor,
                              on device: DeviceCapabilities) -> CompatibilityRating {
        .unsupported(reason: Self.unavailableReason)
    }
}
