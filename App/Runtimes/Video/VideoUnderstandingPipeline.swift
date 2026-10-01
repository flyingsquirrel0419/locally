import Foundation
import LocallyCore
import LocallyRuntime

#if canImport(AVFoundation) && canImport(CoreImage) && canImport(UIKit)
import AVFoundation
import CoreImage
import ImageIO
import UIKit
#endif

/// What the video pipeline hands back at the end of a run.
public struct VideoAnalysisResult: Sendable, Hashable {
    /// The aggregated final answer.
    public var answer: String
    /// Timestamp ranges cited by the model, validated against the duration.
    public var citedRanges: [TimeRange]
    /// Frames actually sampled (may be lower than planned if thermal
    /// pressure rose mid-run).
    public var framesSampled: Int
    public var metadata: InferenceMetadata

    public init(answer: String, citedRanges: [TimeRange], framesSampled: Int,
                metadata: InferenceMetadata = InferenceMetadata()) {
        self.answer = answer
        self.citedRanges = citedRanges
        self.framesSampled = framesSampled
        self.metadata = metadata
    }
}

/// How the pipeline asks about the current device pressure; injected so the
/// pipeline file itself never touches ProcessInfo directly.
public struct VideoPressureProbe: Sendable {
    public var thermalLevel: @Sendable () -> VideoSamplingPlanner.ThermalLevel
    public var lowPowerMode: @Sendable () -> Bool

    public init(
        thermalLevel: @escaping @Sendable () -> VideoSamplingPlanner.ThermalLevel,
        lowPowerMode: @escaping @Sendable () -> Bool
    ) {
        self.thermalLevel = thermalLevel
        self.lowPowerMode = lowPowerMode
    }

    #if canImport(UIKit)
    /// Live probe reading ProcessInfo (main-thread-free reads).
    public static var system: VideoPressureProbe {
        VideoPressureProbe(
            thermalLevel: {
                switch ProcessInfo.processInfo.thermalState {
                case .nominal: return .nominal
                case .fair: return .fair
                case .serious: return .serious
                case .critical: return .critical
                @unknown default: return .fair
                }
            },
            lowPowerMode: { ProcessInfo.processInfo.isLowPowerModeEnabled })
    }
    #endif
}

/// Drives video understanding: sample frames lazily from an asset, feed
/// per-batch prompts to the active VLM runtime, then aggregate the batch
/// answers (map-reduce) into a final answer with cited timestamps.
///
/// The pipeline is not itself an `AIRuntime` — it orchestrates the loaded
/// VLM runtime (kind `.vision`) and reports its own progress phases.
public struct VideoUnderstandingPipeline: Sendable {

    /// Progress phases surfaced as `AIEvent.progress(_, phase:)`.
    public enum Phase: String, Sendable {
        case samplingFrames = "Sampling frames"
        case analyzing = "Analyzing"
        case summarizing = "Summarizing"
    }

    private let planner: VideoSamplingPlanner
    private let aggregation: VideoAggregationPlanner
    private let probe: VideoPressureProbe

    public init(planner: VideoSamplingPlanner = VideoSamplingPlanner(),
                aggregation: VideoAggregationPlanner = VideoAggregationPlanner(),
                probe: VideoPressureProbe) {
        self.planner = planner
        self.aggregation = aggregation
        self.probe = probe
    }

    public enum PipelineError: Error, Sendable {
        case noVideoTrack
        case runtimeCannotRunModel(String)
    }

    /// Run the full analysis for a local video file.
    ///
    /// - Parameters:
    ///   - fileURL: local file URL of the video (already copied off the
    ///     Photos picker).
    ///   - mode / question: what to ask.
    ///   - requestedFrameCount: nil = auto, else 8/16/32.
    ///   - model / runtime: the prepared descriptor and the loaded VLM
    ///     runtime serving it.
    ///   - memoryBudgetBytes: decoded-frame budget from the device probe.
    public func analyze(
        fileURL: URL,
        mode: VideoAggregationPlanner.Mode,
        question: String?,
        requestedFrameCount: Int?,
        model: ModelDescriptor,
        runtime: any AIRuntime,
        memoryBudgetBytes: Int64,
        maxPixelSize: Int
    ) -> AsyncThrowingStream<AIEvent, Error> {
        let requestID = UUID()
        return AsyncThrowingStream { continuation in
            let task = Task {
                await self.execute(
                    requestID: requestID,
                    fileURL: fileURL, mode: mode, question: question,
                    requestedFrameCount: requestedFrameCount, model: model,
                    runtime: runtime, memoryBudgetBytes: memoryBudgetBytes,
                    maxPixelSize: maxPixelSize, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func execute(
        requestID: UUID,
        fileURL: URL,
        mode: VideoAggregationPlanner.Mode,
        question: String?,
        requestedFrameCount: Int?,
        model: ModelDescriptor,
        runtime: any AIRuntime,
        memoryBudgetBytes: Int64,
        maxPixelSize: Int,
        continuation: AsyncThrowingStream<AIEvent, Error>.Continuation
    ) async {
        #if canImport(AVFoundation) && canImport(CoreImage) && canImport(UIKit)
        continuation.yield(.started(requestID: requestID))
        do {
            let asset = AVURLAsset(url: fileURL)
            let duration = try await asset.load(.duration).seconds
            let tracks = try await asset.load(.tracks)
            guard tracks.contains(where: { $0.mediaType == .video }) else {
                throw PipelineError.noVideoTrack
            }

            continuation.yield(.progress(0.05, phase: Phase.samplingFrames.rawValue))

            let imagesPerRequest = VLMTypeRegistry.maxImagesPerRequest(
                for: model.architecture)
            let context = VideoSamplingPlanner.Context(
                duration: duration,
                thermal: probe.thermalLevel(),
                lowPowerMode: probe.lowPowerMode(),
                memoryBudgetBytes: memoryBudgetBytes,
                imagesPerRequest: imagesPerRequest,
                requestedFrameCount: requestedFrameCount)
            let plan = try planner.plan(context)

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            generator.maximumSize = CGSize(
                width: plan.frameTarget.width, height: plan.frameTarget.height)

            var batchAnswers: [String] = []
            var sampled = 0
            var batches = plan.batches
            var aggregatedTokens = 0
            var aggregatedGenerateTime: TimeInterval = 0

            for (batchIndex, timestamps) in batches.enumerated() {
                if Task.isCancelled { throw LocallyError.cancelled }

                // Thermal re-check between batches: on serious pressure,
                // drop the remaining batches (never mid-batch, so timestamp
                // labels stay consistent).
                if batchIndex > 0 {
                    let thermal = probe.thermalLevel()
                    if thermal == .critical {
                        throw LocallyError.inferenceFailed(
                            userMessage: "Video analysis stopped: the device is too hot.",
                            technicalDetail: "thermal state critical at batch \(batchIndex + 1)")
                    }
                    if thermal == .serious || probe.lowPowerMode() {
                        batches = Array(batches.prefix(batchIndex + 1))
                    }
                }

                // Extract this batch's frames lazily — never the whole plan.
                var frames: [Data] = []
                var usedTimestamps: [TimeInterval] = []
                for timestamp in timestamps {
                    if Task.isCancelled { throw LocallyError.cancelled }
                    let time = CMTime(seconds: timestamp, preferredTimescale: 600)
                    guard let cgImage = try? await generator.image(at: time).image
                    else { continue }
                    frames.append(Self.pngData(from: cgImage,
                                               maxPixelSize: maxPixelSize))
                    usedTimestamps.append(timestamp)
                    sampled += 1
                    let fraction = 0.05 + 0.35 * Double(sampled) / Double(plan.frameCount)
                    continuation.yield(.progress(
                        min(fraction, 0.4), phase: Phase.samplingFrames.rawValue))
                }
                guard !frames.isEmpty else { continue }

                let prompt = aggregation.batchPrompt(
                    mode: mode, question: question, timestamps: usedTimestamps)
                let request = Self.vlmRequest(
                    model: model, prompt: prompt, images: frames,
                    maxTokens: 384)
                let progressBase = 0.4 + 0.5 * Double(batchIndex) / Double(batches.count)
                continuation.yield(.progress(
                    progressBase,
                    phase: "\(Phase.analyzing.rawValue) \(batchIndex + 1)/\(batches.count)"))
                let answer = try await Self.collectAnswer(
                    runtime.run(request), into: &aggregatedTokens,
                    generateTime: &aggregatedGenerateTime)
                batchAnswers.append(answer)
            }

            guard !batchAnswers.isEmpty else {
                throw LocallyError.inferenceFailed(
                    userMessage: "No frames could be read from this video.",
                    technicalDetail: "AVAssetImageGenerator produced no frames")
            }

            continuation.yield(.progress(0.9, phase: Phase.summarizing.rawValue))
            let finalAnswer: String
            if batchAnswers.count == 1 {
                finalAnswer = batchAnswers[0]
            } else {
                let reducePrompt = aggregation.aggregationPrompt(
                    mode: mode, question: question, batchAnswers: batchAnswers)
                finalAnswer = try await Self.collectAnswer(
                    runtime.run(Self.vlmRequest(model: model, prompt: reducePrompt,
                                                images: [], maxTokens: 512)),
                    into: &aggregatedTokens,
                    generateTime: &aggregatedGenerateTime)
            }

            let cited = VideoAggregationPlanner.citedRanges(
                in: finalAnswer, duration: duration)
            let metadata = InferenceMetadata(
                ttft: nil,
                tokensPerSecond: aggregatedGenerateTime > 0
                    ? Double(aggregatedTokens) / aggregatedGenerateTime : nil,
                generatedTokens: aggregatedTokens > 0 ? aggregatedTokens : nil)
            let result = VideoAnalysisResult(
                answer: finalAnswer, citedRanges: cited, framesSampled: sampled,
                metadata: metadata)
            continuation.yield(.metadata(metadata))
            continuation.yield(.completed(result: AIResult(
                requestID: requestID,
                text: result.answer,
                artifacts: [],
                metadata: result.metadata)))
            continuation.finish()
        } catch let error as LocallyError {
            continuation.yield(.failed(error))
            continuation.finish()
        } catch PipelineError.noVideoTrack {
            continuation.yield(.failed(.inferenceFailed(
                userMessage: "This file has no video track.",
                technicalDetail: "AVAsset tracks: none of type video")))
            continuation.finish()
        } catch VideoSamplingPlanner.PlanError.refusedThermal {
            continuation.yield(.failed(.inferenceFailed(
                userMessage: "The device is too hot to analyze video right now.",
                technicalDetail: "thermal state critical at planning time")))
            continuation.finish()
        } catch {
            continuation.yield(.failed(.inferenceFailed(
                userMessage: "Video analysis failed.", technicalDetail: "\(error)")))
            continuation.finish()
        }
        #else
        continuation.yield(.failed(.runtimeUnavailable(
            userMessage: "Video understanding is not available in this build.",
            technicalDetail: "AVFoundation/UIKit unavailable")))
        continuation.finish()
        #endif
    }

    /// Collect a full answer from one VLM run; throws the runtime's failure.
    private static func collectAnswer(
        _ stream: AsyncThrowingStream<AIEvent, Error>,
        into tokens: inout Int,
        generateTime: inout TimeInterval
    ) async throws -> String {
        var text = ""
        for try await event in stream {
            switch event {
            case .token(let chunk):
                text += chunk
            case .completed(let result):
                if let answer = result.text, !answer.isEmpty { text = answer }
                if let count = result.metadata.generatedTokens { tokens += count }
            case .failed(let error):
                throw error
            default:
                continue
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A single-turn VLM request carrying images via the JSON payload the
    /// VLM runtime understands (base64; images are already small).
    private static func vlmRequest(model: ModelDescriptor, prompt: String,
                                   images: [Data], maxTokens: Int) -> AIRequest {
        var payload: [String: JSONValue] = ["prompt": .string(prompt)]
        if !images.isEmpty {
            payload["images"] = .array(images.map { .string($0.base64EncodedString()) })
        }
        return AIRequest(
            model: model,
            input: .json(payload),
            parameters: GenerationParameters(temperature: 0.2, maxTokens: maxTokens))
    }

    #if canImport(AVFoundation) && canImport(CoreImage) && canImport(UIKit)
    /// Re-encode a frame as PNG after an ImageIO thumbnail pass guarantees
    /// the pixel budget (AVAssetImageGenerator's maximumSize is a hint).
    private static func pngData(from cgImage: CGImage, maxPixelSize: Int) -> Data {
        let source = CIImage(cgImage: cgImage)
        let extent = source.extent
        let longEdge = max(extent.width, extent.height)
        var image = source
        if longEdge > CGFloat(maxPixelSize) {
            let scale = CGFloat(maxPixelSize) / longEdge
            image = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let context = CIContext()
        guard let scaled = context.createCGImage(image, from: image.extent) else {
            return Data()
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, scaled, nil)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return data as Data
    }
    #endif
}
