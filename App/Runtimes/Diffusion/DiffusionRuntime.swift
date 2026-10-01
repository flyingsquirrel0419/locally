import Foundation
import LocallyCore
import LocallyRuntime

/// Image-generation runtime for Core ML diffusion models, backed by Apple's
/// ml-stable-diffusion Swift package on iOS. Compiled out everywhere else;
/// the router then honestly reports diffusion as unavailable.
///
/// Input encoding: the prompt is a `.text` input; generation knobs travel in
/// `parameters` (`seed` reused as the diffusion seed, `maxTokens` reused as
/// the step count) and in `model.metadata["diffusion_*"]` set by the
/// repository analyzer.
#if canImport(StableDiffusion) && canImport(CoreML) && canImport(UIKit)
import CoreML
import StableDiffusion
import UIKit

public final class DiffusionRuntime: ModelCompatibleRuntime, @unchecked Sendable {
    public let kind: RuntimeKind = .diffusion

    private let planner = DiffusionPlanner()

    /// ml-stable-diffusion's `StableDiffusionPipelineProtocol` is not
    /// `Sendable`, but pipelines are only touched from one detached task at
    /// a time (load, generate, or unload), which this box asserts. Access is
    /// additionally funnelled through the `State` actor below.
    private struct PipelineBox: @unchecked Sendable {
        let value: any StableDiffusionPipelineProtocol
    }

    /// Loaded pipeline plus the configuration it was loaded with. Guarded by
    /// an actor; a run holds a strong reference for its whole duration so
    /// `unload()` mid-run releases memory only after generation ends.
    private actor State {
        var pipeline: PipelineBox?
        var loadTime: TimeInterval = 0
        var cancelled = false
        func store(_ pipeline: PipelineBox, _ loadTime: TimeInterval) {
            self.pipeline = pipeline
            self.loadTime = loadTime
            self.cancelled = false
        }
        func clear() { pipeline = nil }
        func cancel() { cancelled = true }
    }
    private let state = State()

    public init() {}

    // MARK: - Compatibility

    public func compatibility(with model: ModelDescriptor,
                              on device: DeviceCapabilities) -> CompatibilityRating {
        guard model.modality == .imageGeneration else {
            return .unsupported(reason: "diffusion runtime handles image generation only")
        }
        guard model.formats.contains(.coreml) else {
            return .unsupported(reason: "model is not a Core ML diffusion package")
        }
        guard model.metadata["diffusion_resources_dir"] != nil else {
            return .unsupported(reason: "no runnable Core ML diffusion variant was selected")
        }
        if device.physicalMemory < 3 * 1024 * 1024 * 1024 {
            return .unsupported(reason: "image generation needs at least 3 GB of memory")
        }
        if model.metadata["diffusion_attention"] == "original" {
            return .risky(reason: "original-attention UNet cannot use the Neural Engine and runs slowly on iPhone")
        }
        return .supported
    }

    public func isSupported(on device: DeviceCapabilities) -> Bool { true }

    // MARK: - Lifecycle

    /// Loads the pipeline off the main thread. The installed resource
    /// directory is `<modelDir>/<diffusion_resources_dir>`; for archive-form
    /// installs the archive has already been expanded by the installer.
    public func load(_ model: ModelDescriptor) async throws {
        guard let base = model.metadata["localDirectory"],
              let resources = model.metadata["diffusion_resources_dir"] else {
            throw LocallyError.modelNotFound(
                userMessage: "The model resources are not available on disk.",
                technicalDetail: "localDirectory or diffusion_resources_dir missing for \(model.repoID)")
        }
        let resourceURL = URL(fileURLWithPath: base).appendingPathComponent(resources)
        let fm = FileManager.default
        // A flat-directory install (extracted zip) holds the .mlmodelc
        // folders directly; accept both flat and single-nested layouts.
        let root: URL
        if fm.fileExists(atPath: resourceURL.appendingPathComponent("Unet.mlmodelc").path)
            || fm.fileExists(atPath: resourceURL.appendingPathComponent("UnetChunk1.mlmodelc").path) {
            root = resourceURL
        } else if let nested = onlyDirectory(in: resourceURL),
                  fm.fileExists(atPath: nested.appendingPathComponent("Unet.mlmodelc").path)
                    || fm.fileExists(atPath: nested.appendingPathComponent("UnetChunk1.mlmodelc").path) {
            root = nested
        } else {
            throw LocallyError.modelNotFound(
                userMessage: "The downloaded package doesn't contain a UNet model.",
                technicalDetail: "no Unet.mlmodelc under \(resourceURL.path)")
        }

        let reduceMemory = ProcessInfo.processInfo.physicalMemory < 8 * 1024 * 1024 * 1024
        let attention = model.metadata["diffusion_attention"] ?? "split_einsum"
        let started = Date()
        let box: PipelineBox = try await Task.detached(priority: .userInitiated) {
            let configuration = MLModelConfiguration()
            // split_einsum is required for the Neural Engine; original
            // attention runs on the GPU instead.
            configuration.computeUnits = attention == "original"
                ? .cpuAndGPU : .cpuAndNeuralEngine
            let isXL = model.metadata["diffusion_resolution"] == "1024"
            let pipeline: any StableDiffusionPipelineProtocol
            if isXL {
                pipeline = try StableDiffusionXLPipeline(
                    resourcesAt: root, configuration: configuration,
                    reduceMemory: reduceMemory)
            } else {
                pipeline = try StableDiffusionPipeline(
                    resourcesAt: root, controlNet: [], configuration: configuration,
                    disableSafety: false, reduceMemory: reduceMemory)
            }
            return PipelineBox(value: pipeline)
        }.value
        // Eagerly load (or prewarm, in reduceMemory mode) so the first run
        // isn't charged for model compilation.
        try await Task.detached(priority: .userInitiated) {
            try box.value.loadResources()
        }.value
        await state.store(box, Date().timeIntervalSince(started))
    }

    public func unload() async {
        let box = await state.pipeline
        await state.clear()
        if let box {
            await Task.detached(priority: .utility) { box.value.unloadResources() }.value
        }
    }

    private func onlyDirectory(in url: URL) -> URL? {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey])
        let directories = contents?.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        return directories?.count == 1 ? directories?.first : nil
    }

    // MARK: - Run

    /// Request contract: `.text` input is the prompt; `parameters.seed`
    /// carries the diffusion seed (randomized by the planner when nil);
    /// `parameters.maxTokens` carries the step count; negative prompt and
    /// guidance ride in `model.metadata` overrides set by the UI
    /// (`DiffusionPlanner.negativePromptMetadataKey` /
    ///  `DiffusionPlanner.guidanceMetadataKey`).
    public func run(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [planner, state] in
                continuation.yield(.started(requestID: request.id))

                // Thermal gate: critical refuses, serious warns.
                switch ProcessInfo.processInfo.thermalState {
                case .critical:
                    continuation.yield(.failed(.runtimeUnavailable(
                        userMessage: "The device is too hot to generate images right now.",
                        technicalDetail: "thermalState == .critical")))
                    continuation.finish()
                    return
                case .serious:
                    continuation.yield(.preparing("Device is warm; generation will be slower"))
                default: break
                }

                guard case .text(let prompt) = request.input else {
                    continuation.yield(.failed(.unsupportedModality(
                        userMessage: "Image generation takes a text prompt.",
                        technicalDetail: "input was not .text")))
                    continuation.finish()
                    return
                }

                var plan: DiffusionPlanner.Plan
                do {
                    let negative = request.model.metadata[DiffusionPlanner.negativePromptMetadataKey] ?? ""
                    let guidance = Double(request.model.metadata[DiffusionPlanner.guidanceMetadataKey] ?? "") ?? 7.5
                    plan = try planner.plan(
                        .init(prompt: prompt, negativePrompt: negative,
                              stepCount: max(1, min(50, request.parameters.maxTokens)),
                              seed: request.parameters.seed.map { UInt32(truncatingIfNeeded: $0) },
                              guidanceScale: guidance),
                        for: request.model,
                        physicalMemory: ProcessInfo.processInfo.physicalMemory)
                } catch {
                    continuation.yield(.failed(.inferenceFailed(
                        userMessage: "These generation settings aren't valid.",
                        technicalDetail: "\(error)")))
                    continuation.finish()
                    return
                }
                for warning in plan.warnings {
                    continuation.yield(.preparing(warning))
                }

                guard let box = await state.pipeline else {
                    continuation.yield(.failed(.runtimeUnavailable(
                        userMessage: "The model isn't loaded yet.",
                        technicalDetail: "run called before load")))
                    continuation.finish()
                    return
                }
                let pipeline = box.value

                continuation.yield(.preparing("Loading model"))
                let started = Date()
                do {
                    var configuration = PipelineConfiguration(prompt: plan.prompt)
                    configuration.negativePrompt = plan.negativePrompt
                    configuration.stepCount = plan.stepCount
                    configuration.seed = plan.seed
                    configuration.guidanceScale = plan.guidanceScale
                    configuration.imageCount = plan.imageCount
                    configuration.schedulerType = .dpmSolverMultistepScheduler

                    let images: [CGImage?] = try await withCheckedThrowingContinuation { probe in
                        Task.detached(priority: .userInitiated) {
                            do {
                                let result = try pipeline.generateImages(
                                    configuration: configuration
                                ) { progress -> Bool in
                                    let done = progress.step + 1
                                    continuation.yield(.progress(
                                        Double(done) / Double(progress.stepCount),
                                        phase: "Step \(done) / \(progress.stepCount)"))
                                    if Task.isCancelled {
                                        Task { await state.cancel() }
                                        return false
                                    }
                                    return true
                                }
                                probe.resume(returning: result)
                            } catch {
                                probe.resume(throwing: error)
                            }
                        }
                    }

                    if Task.isCancelled {
                        continuation.yield(.failed(.cancelled))
                        continuation.finish()
                        return
                    }

                    continuation.yield(.preparing("Rendering"))
                    var artifacts: [AIResult.Artifact] = []
                    for image in images {
                        guard let image else { continue }  // safety-filtered
                        let uiImage = UIImage(cgImage: image)
                        guard let png = uiImage.pngData() else { continue }
                        artifacts.append(.image(png))
                        continuation.yield(.image(png))
                    }
                    guard !artifacts.isEmpty else {
                        continuation.yield(.failed(.inferenceFailed(
                            userMessage: "The safety filter blocked the generated image.",
                            technicalDetail: "all images were nil after safety check")))
                        continuation.finish()
                        return
                    }

                    let elapsed = Date().timeIntervalSince(started)
                    let metadata = InferenceMetadata(
                        loadTime: nil, ttft: nil,
                        tokensPerSecond: elapsed > 0
                            ? Double(plan.stepCount) / elapsed : nil,
                        generatedTokens: plan.stepCount)
                    continuation.yield(.metadata(metadata))
                    continuation.yield(.completed(result: AIResult(
                        requestID: request.id,
                        artifacts: artifacts,
                        metadata: metadata)))
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.yield(.failed(.cancelled))
                    } else {
                        continuation.yield(.failed(.inferenceFailed(
                            userMessage: "Image generation failed.",
                            technicalDetail: "\(error)")))
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
