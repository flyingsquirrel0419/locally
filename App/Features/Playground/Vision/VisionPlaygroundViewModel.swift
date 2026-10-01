import Foundation
import LocallyCore
import LocallyRuntime
import Observation

/// Drives the vision playground: owns the picked images (as raw data plus
/// thumbnails), streams VLM runtime events, and exposes metrics. Images are
/// downsampled off the main actor before they ever reach the runtime.
@Observable
@MainActor
final class VisionPlaygroundViewModel {
    /// One picked image: raw bytes (kept for inference) plus a small
    /// thumbnail for display.
    struct PickedImage: Identifiable {
        let id = UUID()
        let data: Data
        let thumbnailData: Data
        let sourceWidth: Int
        let sourceHeight: Int
    }

    struct Metrics {
        var loadTime: TimeInterval?
        var ttft: TimeInterval?
        var tokensPerSecond: Double?
        var generatedTokens: Int?
    }

    private(set) var images: [PickedImage] = []
    private(set) var answer = ""
    private(set) var metrics = Metrics()
    private(set) var lastError: String?
    private(set) var planSummary: String?

    var prompt = ""
    var maxTokens = 512
    var temperature = 0.2
    var isGenerating: Bool { generationTask != nil }

    private let model: ModelDescriptor
    private let router: RuntimeRouter
    private let device: DeviceCapabilities
    private let planner = ImagePreprocessingPlanner()
    private var runtime: (any ModelCompatibleRuntime)?
    private var generationTask: Task<Void, Never>?
    private var loadAttempted = false

    init(model: ModelDescriptor, router: RuntimeRouter, device: DeviceCapabilities) {
        self.model = model
        self.router = router
        self.device = device
    }

    var decision: RuntimeRouter.Decision {
        router.decide(for: model, on: device)
    }

    /// Multi-image ceiling for this model family.
    var maxImages: Int {
        VLMTypeRegistry.maxImagesPerRequest(for: model.architecture)
    }

    var canRun: Bool {
        !images.isEmpty && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isGenerating && runtime != nil
    }

    func prepareIfNeeded() async {
        guard !loadAttempted else { return }
        loadAttempted = true
        guard let runtime = router.runtime(for: model, on: device) else { return }
        do {
            try await runtime.load(model)
            self.runtime = runtime
            metrics.loadTime = nil
        } catch let error as LocallyError {
            lastError = error.userMessage
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Add picked images: decode dimensions from headers, build a small
    /// display thumbnail, and refresh the plan preview. Runs off-main for
    /// the thumbnail work via a detached task per image.
    func addImages(datas: [Data]) async {
        let remaining = max(0, maxImages - images.count)
        for data in datas.prefix(remaining) {
            let picked = await Task.detached(priority: .userInitiated) {
                Self.makePickedImage(data: data)
            }.value
            if let picked { images.append(picked) }
        }
        refreshPlanSummary()
    }

    func removeImage(id: UUID) {
        images.removeAll { $0.id == id }
        refreshPlanSummary()
    }

    private func refreshPlanSummary() {
        let probe = VisionCompatibilityProbe(planner: planner)
        let sources = images.map {
            ImagePreprocessingPlanner.PixelSize(width: $0.sourceWidth,
                                                height: $0.sourceHeight)
        }
        let estimate = probe.estimate(sources: sources, config: .init())
        guard !estimate.plans.isEmpty else {
            planSummary = nil
            return
        }
        let megapixels = estimate.plans.reduce(0) { $0 + $1.target.pixels } / 1_000_000
        planSummary = String(
            format: "%d image(s) → ~%d image tokens, %lld MP after resize",
            estimate.plans.count, estimate.totalEstimatedTokens, megapixels)
    }

    func run() {
        guard canRun, let runtime else { return }
        lastError = nil
        answer = ""

        // Payload the VLM runtime understands: prompt + base64 images.
        var payload: [String: JSONValue] = ["prompt": .string(prompt)]
        payload["images"] = .array(images.map { .string($0.data.base64EncodedString()) })
        let request = AIRequest(
            model: model,
            input: .json(payload),
            parameters: GenerationParameters(
                temperature: temperature, maxTokens: maxTokens))

        generationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.generationTask = nil }
            do {
                for try await event in runtime.run(request) {
                    if Task.isCancelled { break }
                    switch event {
                    case .token(let chunk):
                        answer += chunk
                    case .completed(let result):
                        if let text = result.text { answer = text }
                        metrics.ttft = result.metadata.ttft
                        metrics.tokensPerSecond = result.metadata.tokensPerSecond
                        metrics.generatedTokens = result.metadata.generatedTokens
                        metrics.loadTime = result.metadata.loadTime
                    case .failed(let error):
                        if case .cancelled = error { break }
                        lastError = error.userMessage
                    default:
                        continue
                    }
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func stop() {
        generationTask?.cancel()
        generationTask = nil
    }

    /// Decode header dimensions and render a display thumbnail without
    /// ever decoding the full image (ImageIO thumbnail path).
    private static func makePickedImage(data: Data) -> PickedImage? {
        #if canImport(ImageIO) && canImport(CoreImage) && canImport(UIKit)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        var thumbnailData = data
        if let cgThumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary) {
            let image = UIImage(cgImage: cgThumbnail)
            if let jpeg = image.jpegData(compressionQuality: 0.8) {
                thumbnailData = jpeg
            }
        }
        return PickedImage(data: data, thumbnailData: thumbnailData,
                           sourceWidth: width, sourceHeight: height)
        #else
        return nil
        #endif
    }
}
