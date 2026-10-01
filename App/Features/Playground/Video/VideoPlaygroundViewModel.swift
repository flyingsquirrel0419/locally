import Foundation
import LocallyCore
import LocallyRuntime
import Observation

/// Drives the video-understanding playground: holds the picked video as a
/// temp file, owns the analysis task, and surfaces progress, the final
/// answer, and cited timestamp ranges.
@Observable
@MainActor
final class VideoPlaygroundViewModel {
    /// One cited moment, tappable in the UI to seek the preview player.
    struct CitedMoment: Identifiable, Hashable {
        var id: TimeInterval { range.start }
        let range: TimeRange
    }

    enum FrameBudget: String, CaseIterable, Identifiable {
        case auto, frames8, frames16, frames32
        var id: String { rawValue }

        var count: Int? {
            switch self {
            case .auto: return nil
            case .frames8: return 8
            case .frames16: return 16
            case .frames32: return 32
            }
        }
    }

    private(set) var videoFileURL: URL?
    private(set) var videoDuration: TimeInterval = 0
    private(set) var answer = ""
    private(set) var citedMoments: [CitedMoment] = []
    private(set) var progressPhase: String?
    private(set) var progress: Double = 0
    private(set) var framesSampled = 0
    private(set) var lastError: String?
    private(set) var planReason: String?

    var mode: VideoAggregationPlanner.Mode = .describe
    var question = ""
    var frameBudget: FrameBudget = .auto
    var isAnalyzing: Bool { analysisTask != nil }

    private let model: ModelDescriptor
    private let router: RuntimeRouter
    private let device: DeviceCapabilities
    private var runtime: (any ModelCompatibleRuntime)?
    private var analysisTask: Task<Void, Never>?
    private var loadAttempted = false

    init(model: ModelDescriptor, router: RuntimeRouter, device: DeviceCapabilities) {
        self.model = model
        self.router = router
        self.device = device
    }

    var decision: RuntimeRouter.Decision {
        router.decide(for: model, on: device)
    }

    var canAnalyze: Bool {
        videoFileURL != nil && !isAnalyzing && runtime != nil
            && (mode != .question
                || !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func prepareIfNeeded() async {
        guard !loadAttempted else { return }
        loadAttempted = true
        guard let runtime = router.runtime(for: model, on: device) else { return }
        do {
            try await runtime.load(model)
            self.runtime = runtime
        } catch let error as LocallyError {
            lastError = error.userMessage
        } catch {
            lastError = ErrorPresentation.userMessage(for: error)
        }
    }

    /// Surface a picker/loading error from the view (e.g. when
    /// `loadTransferable` fails before we have a URL to work with).
    func reportPickerFailure(_ message: String) {
        lastError = message
    }

    /// PhotosPicker hands us a Movie whose URL may be transient; copy it
    /// into our own temp location so the pipeline can reopen it freely.
    func setVideo(data tempSource: URL, duration: TimeInterval) {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("locally-video-\(UUID().uuidString).mov")
        do {
            if let existing = videoFileURL {
                try? FileManager.default.removeItem(at: existing)
            }
            try FileManager.default.copyItem(at: tempSource, to: destination)
            videoFileURL = destination
            videoDuration = duration
            answer = ""
            citedMoments = []
            lastError = nil
            planReason = nil
        } catch {
            lastError = ErrorPresentation.userMessage(for: error)
        }
    }

    func analyze() {
        guard canAnalyze, let runtime, let fileURL = videoFileURL else { return }
        lastError = nil
        answer = ""
        citedMoments = []
        progress = 0
        progressPhase = nil

        // The policy-aware probe folds ResourcePolicyObserver's frame-budget
        // scale (thermal/low-power pressure) into the planner's live state.
        let pipeline = VideoUnderstandingPipeline(probe: .policyAware())
        let budget = Int64(min(device.physicalMemory / 4, 1_000_000_000))
        let requested = frameBudget.count
        let mode = self.mode
        let question = self.question
        let model = self.model

        analysisTask = Task { [weak self] in
            guard let self else { return }
            defer { self.analysisTask = nil }
            do {
                let stream = pipeline.analyze(
                    fileURL: fileURL, mode: mode,
                    question: question.isEmpty ? nil : question,
                    requestedFrameCount: requested,
                    model: model, runtime: runtime,
                    memoryBudgetBytes: budget,
                    maxPixelSize: ImagePreprocessingPlanner().maxLongEdge)
                for try await event in stream {
                    if Task.isCancelled { break }
                    switch event {
                    case .progress(let fraction, let phase):
                        progress = fraction
                        progressPhase = phase
                    case .token(let chunk):
                        answer += chunk
                    case .completed(let result):
                        if let text = result.text { answer = text }
                        citedMoments = VideoAggregationPlanner.citedRanges(
                            in: answer, duration: videoDuration
                        ).map { CitedMoment(range: $0) }
                        progress = 1
                        progressPhase = nil
                    case .failed(let error):
                        progressPhase = nil
                        if case .cancelled = error { break }
                        lastError = error.userMessage
                    default:
                        continue
                    }
                }
            } catch {
                lastError = ErrorPresentation.userMessage(for: error)
            }
        }
    }

    func stop() {
        analysisTask?.cancel()
        analysisTask = nil
        progressPhase = nil
    }

    func cleanup() {
        stop()
        if let url = videoFileURL {
            try? FileManager.default.removeItem(at: url)
            videoFileURL = nil
        }
    }
}
