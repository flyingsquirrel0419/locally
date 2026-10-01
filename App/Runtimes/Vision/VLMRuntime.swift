import Foundation
import LocallyCore
import LocallyDevice
import LocallyRuntime

#if canImport(MLXVLM) && canImport(UIKit)
import CoreImage
import ImageIO
import MLX
import MLXLMCommon
import MLXVLM
import UIKit
#endif

/// Vision-language runtime for MLX-format VLMs, backed by the MLXVLM
/// library of ml-explore/mlx-swift-lm 3.31.4. Compiled out when MLXVLM is
/// unavailable; compatibility then reports honestly that the library is not
/// linked.
///
/// Verified against the pinned sources (3.31.4):
///   - `VLMModelFactory.shared.loadContainer(from: URL, using: TokenizerLoader)`
///     loads a local directory (no network path is taken).
///   - Generation: `container.prepare(input: UserInput)` then
///     `container.generate(input: LMInput, parameters: GenerateParameters)`
///     returning `AsyncStream<Generation>` (`.chunk` / `.info` / `.toolCall`).
///   - `UserInput(prompt: String, images: [UserInput.Image])` and
///     `UserInput(chat: [Chat.Message], processing:)`; images are
///     `.ciImage(CIImage)`; per-request pixel budget overrides live on
///     `UserInput.Processing(minPixels:maxPixels:)`.
///   - Known architectures: `VLMTypeRegistry.shared` creators map.
public final class VLMRuntime: ModelCompatibleRuntime, @unchecked Sendable {
    public let kind: RuntimeKind = .vision

    /// `true` when MLXVLM is compiled into the build.
    public static var isLibraryLinked: Bool {
        #if canImport(MLXVLM) && canImport(UIKit)
        return true
        #else
        return false
        #endif
    }

    /// Known architectures, re-exported from the pure registry in
    /// LocallyRuntime so the app layer never hardcodes its own list.
    public static var knownModelTypes: Set<String> {
        Set(VLMTypeRegistry.knownTypes.map(\.modelType))
    }

    /// Fixed cap for MLX's Metal buffer cache (same value as MLXRuntime).
    public static let cacheLimitBytes = 64 * 1024 * 1024

    #if canImport(MLXVLM) && canImport(UIKit)
    private actor LoadState {
        var container: ModelContainer?
        var loadTime: TimeInterval = 0
        var peakMemoryAtLoad: Int64 = 0
        /// preprocessor_config.json bytes, kept for the planner.
        var preprocessorConfig: Data?

        func store(_ container: ModelContainer, loadTime: TimeInterval,
                   peakMemory: Int64, preprocessorConfig: Data?) {
            self.container = container
            self.loadTime = loadTime
            self.peakMemoryAtLoad = peakMemory
            self.preprocessorConfig = preprocessorConfig
        }
        func clear() {
            container = nil
            loadTime = 0
            peakMemoryAtLoad = 0
            preprocessorConfig = nil
        }
        func current() -> (ModelContainer, TimeInterval, Int64, Data?)? {
            guard let container else { return nil }
            return (container, loadTime, peakMemoryAtLoad, preprocessorConfig)
        }
    }
    private let state = LoadState()

    #endif

    /// Thermal pacing hook, awaited between generated tokens. Default no-op;
    /// RuntimeRegistry injects the policy-backed pacer.
    private let pacer: any GenerationPacer

    // Memory warnings are handled app-wide by ResourcePolicyObserver; this
    // runtime registers no NotificationCenter observers of its own.
    public init(pacer: any GenerationPacer = NoOpGenerationPacer()) {
        self.pacer = pacer
    }

    // MARK: - Compatibility

    public func compatibility(with model: ModelDescriptor,
                              on device: DeviceCapabilities) -> CompatibilityRating {
        guard Self.isLibraryLinked else {
            return .unsupported(reason: "MLXVLM libraries are not linked into this build")
        }
        guard device.metalAvailable else {
            return .unsupported(reason: "MLX requires a Metal device; unavailable on Simulator")
        }
        return compatibility(modality: model.modality, formats: model.formats,
                             architecture: model.architecture)
    }

    /// Compatibility without a device probe (device-independent checks).
    public func compatibility(modality: ModelModality, formats: [ModelFormat],
                              architecture: String?) -> CompatibilityRating {
        guard Self.isLibraryLinked else {
            return .unsupported(reason: "MLXVLM libraries are not linked into this build")
        }
        return VLMTypeRegistry.rate(modality: modality, formats: formats,
                                    architecture: architecture)
    }

    public func isSupported(on device: DeviceCapabilities) -> Bool {
        Self.isLibraryLinked && device.metalAvailable
    }

    // MARK: - Lifecycle

    /// Load an installed MLX VLM from its on-disk directory. No network:
    /// the downloader path of the factory is never used.
    public func load(_ model: ModelDescriptor) async throws {
        #if canImport(MLXVLM) && canImport(UIKit)
        guard let path = model.metadata["localDirectory"], !path.isEmpty else {
            throw LocallyError.modelNotFound(
                userMessage: "The model files are not available on disk.",
                technicalDetail: "no localDirectory in metadata for \(model.repoID)")
        }
        let directory = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("config.json").path) else {
            throw LocallyError.modelNotFound(
                userMessage: "The model files are incomplete.",
                technicalDetail: "config.json missing in \(path)")
        }

        // Bound MLX's allocator to the shared device safe budget before
        // loading (same heuristic as MLXRuntime).
        let physical = ProcessInfo.processInfo.physicalMemory
        MLX.Memory.memoryLimit = Int(MemoryBudget.safeAIBudget(
            physicalMemory: physical, availableEstimate: physical))
        MLX.Memory.cacheLimit = Self.cacheLimitBytes

        // Keep the preprocessor config for the image planner; optional.
        let preprocessorConfig = try? Data(contentsOf:
            directory.appendingPathComponent("preprocessor_config.json"))

        let start = ContinuousClock.now
        do {
            let container = try await VLMModelFactory.shared.loadContainer(
                from: directory, using: TransformersTokenizerLoader())
            await state.store(
                container,
                loadTime: start.duration(to: .now).magnitudeSecondsVLM,
                peakMemory: Int64(MLX.Memory.peakMemory),
                preprocessorConfig: preprocessorConfig)
        } catch let error as LocallyError {
            throw error
        } catch {
            throw LocallyError.inferenceFailed(
                userMessage: "The vision model couldn't be loaded.",
                technicalDetail: "\(error)")
        }
        #else
        throw LocallyError.runtimeUnavailable(
            userMessage: "Vision inference is not available in this build.",
            technicalDetail: "MLXVLM not linked (requires an Apple GPU build)")
        #endif
    }

    public func unload() async {
        #if canImport(MLXVLM) && canImport(UIKit)
        await state.clear()
        MLX.Memory.clearCache()
        #endif
    }

    /// The loaded model's preprocessor config, when known (for the
    /// playground's token/memory preview).
    public func loadedPreprocessorConfig() async -> ImagePreprocessingPlanner.ProcessorConfig? {
        #if canImport(MLXVLM) && canImport(UIKit)
        guard let data = await state.current()?.3 else { return nil }
        return ImagePreprocessingPlanner.ProcessorConfig.parse(json: data)
        #else
        return nil
        #endif
    }

    // MARK: - Execution

    public func run(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.execute(request: request, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    #if canImport(MLXVLM) && canImport(UIKit)
    /// Downsample an image without ever decoding the full original:
    /// CGImageSourceCreateThumbnailAtIndex renders straight at the target
    /// size. Returns nil when the data is not a decodable image.
    static func downsampledCIImage(from data: Data, maxPixelSize: Int) -> CIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData,
                                                       options as CFDictionary) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return CIImage(cgImage: cgImage)
    }
    #endif

    private func execute(request: AIRequest,
                         continuation: AsyncThrowingStream<AIEvent, Error>.Continuation) async {
        #if canImport(MLXVLM) && canImport(UIKit)
        continuation.yield(.started(requestID: request.id))
        let start = ContinuousClock.now
        do {
            guard let (container, loadTime, peakAtLoad, preprocessorData) =
                    await state.current() else {
                throw LocallyError.runtimeUnavailable(
                    userMessage: "No vision model is loaded.",
                    technicalDetail: "run() before load()")
            }

            continuation.yield(.preparing("Preparing images"))

            // Split the request input into chat messages and raw images.
            var prompt = ""
            var system: String?
            var imageDatas: [Data] = []
            switch request.input {
            case .text(let text):
                prompt = text
            case .image(let data):
                imageDatas = [data]
            case .chat(let messages):
                for message in messages {
                    switch message.role {
                    case .system: system = message.content
                    case .user, .tool:
                        prompt = prompt.isEmpty ? message.content
                            : prompt + "\n" + message.content
                    case .assistant:
                        break // single-turn: prior answers are not replayed
                    }
                }
            case .json(let object):
                // The video pipeline and structured callers hand over:
                // {"prompt": "...", "images": ["<base64>", ...]}.
                if case .string(let text) = object["prompt"] { prompt = text }
                if case .array(let items) = object["images"] {
                    imageDatas = items.compactMap {
                        guard case .string(let base64) = $0 else { return nil }
                        return Data(base64Encoded: base64)
                    }
                }
            default:
                break
            }

            let architecture = request.model.architecture
            let imageLimit = VLMTypeRegistry.maxImagesPerRequest(for: architecture)
            if imageDatas.count > imageLimit {
                imageDatas = Array(imageDatas.prefix(imageLimit))
            }

            let planner = ImagePreprocessingPlanner()
            let config = preprocessorData
                .flatMap(ImagePreprocessingPlanner.ProcessorConfig.parse(json:))
                ?? ImagePreprocessingPlanner.ProcessorConfig()

            var images: [UserInput.Image] = []
            for data in imageDatas {
                if Task.isCancelled { throw LocallyError.cancelled }
                // Read the source dimensions from the header alone (no
                // decode), plan, then thumbnail straight to the target.
                var maxPixel = planner.maxLongEdge
                if let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
                   let width = properties[kCGImagePropertyPixelWidth] as? Int,
                   let height = properties[kCGImagePropertyPixelHeight] as? Int,
                   let plan = try? planner.plan(
                    source: .init(width: width, height: height), config: config) {
                    maxPixel = plan.target.longEdge
                }
                guard let image = Self.downsampledCIImage(from: data,
                                                          maxPixelSize: maxPixel) else {
                    throw LocallyError.inferenceFailed(
                        userMessage: "One of the selected images couldn't be read.",
                        technicalDetail: "CGImageSource thumbnail creation failed")
                }
                images.append(.ciImage(image))
            }

            var chat: [Chat.Message] = []
            if let system,
               !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chat.append(.system(system))
            }
            chat.append(.user(prompt, images: images))
            let processing = UserInput.Processing(
                maxPixels: config.maxPixels.map { min($0, planner.fallbackMaxPixels) }
                    ?? planner.fallbackMaxPixels)
            let userInput = UserInput(chat: chat, processing: processing)

            let parameters = GenerateParameters(
                maxTokens: request.parameters.maxTokens,
                maxKVSize: request.parameters.contextLength,
                temperature: Float(request.parameters.temperature),
                topP: Float(request.parameters.topP),
                topK: request.parameters.topK ?? 0,
                seed: request.parameters.seed)

            continuation.yield(.preparing("Encoding images"))
            let input = try await container.prepare(input: userInput)
            let stream = try await container.generate(input: input, parameters: parameters)

            var generated = ""
            var info: GenerateCompletionInfo?
            streamLoop: for await generation in stream {
                if Task.isCancelled {
                    continuation.yield(.failed(.cancelled))
                    continuation.finish()
                    return
                }
                switch generation {
                case .chunk(let text):
                    generated += text
                    continuation.yield(.token(text))
                    await pacer.pace()
                    if request.parameters.stop.contains(where: { generated.hasSuffix($0) }) {
                        break streamLoop
                    }
                case .info(let completionInfo):
                    info = completionInfo
                case .toolCall:
                    continue
                }
            }

            let elapsed = start.duration(to: .now).magnitudeSecondsVLM
            let ttft: TimeInterval? = info.map { elapsed - $0.generateTime }
            let peakMemory = await container.perform { _ in Int64(MLX.Memory.peakMemory) }
            let metadata = InferenceMetadata(
                loadTime: loadTime,
                ttft: ttft ?? (info != nil ? elapsed : nil),
                tokensPerSecond: info?.tokensPerSecond,
                generatedTokens: info?.generationTokenCount,
                peakMemoryBytes: max(peakMemory, peakAtLoad))
            continuation.yield(.completed(result: AIResult(
                requestID: request.id, text: generated, metadata: metadata)))
            continuation.finish()
        } catch let error as LocallyError {
            continuation.yield(.failed(error))
            continuation.finish()
        } catch {
            continuation.yield(.failed(.inferenceFailed(
                userMessage: "Vision inference failed.", technicalDetail: "\(error)")))
            continuation.finish()
        }
        #else
        continuation.yield(.failed(.runtimeUnavailable(
            userMessage: "Vision inference is not available in this build.",
            technicalDetail: "MLXVLM not linked")))
        continuation.finish()
        #endif
    }
}

/// Duration → seconds (local to this file; the shared extension used by
/// MLXRuntime is private to that file).
private extension Duration {
    var magnitudeSecondsVLM: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
