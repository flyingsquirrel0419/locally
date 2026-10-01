import Foundation
import LocallyCore
import LocallyRuntime

/// Drives the image-generation playground: parameter state, one generation
/// task at a time, phase text straight from the runtime's events. Nothing
/// is simulated — the seed shown is the seed actually used.
@Observable
@MainActor
final class ImageGenerationViewModel {
    var prompt = ""
    var negativePrompt = ""
    var stepCount = 20
    var guidance = 7.5
    /// nil = randomize on each run; the used seed is reported back.
    var seedText = ""

    private(set) var isGenerating = false
    private(set) var phase: String?
    private(set) var progress: Double?
    private(set) var images: [Data] = []
    private(set) var lastSeedUsed: UInt32?
    private(set) var lastSeconds: TimeInterval?
    private(set) var lastError: String?
    private(set) var loadError: String?

    private let model: ModelDescriptor
    private let registry: RuntimeRegistry
    private var generationTask: Task<Void, Never>?

    init(model: ModelDescriptor, registry: RuntimeRegistry) {
        self.model = model
        self.registry = registry
    }

    /// The model's compiled-in output resolution, when the analyzer knew it.
    var resolution: Int? {
        model.architectureHints?.diffusionResolution
            ?? Int(model.metadata["diffusion_resolution"] ?? "")
    }

    func prepareIfNeeded() async {
        guard registry.loadedRepoID != model.repoID else { return }
        do {
            _ = try await registry.load(model: model)
        } catch let error as LocallyError {
            loadError = error.userMessage
        } catch {
            loadError = error.localizedDescription
        }
    }

    var canGenerate: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isGenerating && loadError == nil
    }

    func generate() {
        guard canGenerate else { return }
        isGenerating = true
        lastError = nil
        phase = nil
        progress = nil
        images = []
        lastSeedUsed = nil

        var descriptor = model
        descriptor.metadata[DiffusionPlanner.negativePromptMetadataKey] = negativePrompt
        descriptor.metadata[DiffusionPlanner.guidanceMetadataKey] = String(guidance)
        // The seed shown is the seed used: randomize here when the field is
        // empty so the UI can display it afterwards.
        let concreteSeed = UInt32(seedText) ?? UInt32.random(in: 1...UInt32.max)
        let seed = UInt64(concreteSeed)
        let request = AIRequest(
            model: descriptor,
            input: .text(prompt),
            parameters: GenerationParameters(maxTokens: stepCount, seed: seed))

        generationTask = Task { [weak self] in
            guard let self else { return }
            guard let runtime = registry.router.runtime(for: descriptor, on: registry.device) else {
                await MainActor.run {
                    self.lastError = String(localized: "imagegen.error.noRuntime",
                                            table: "ImageGeneration")
                    self.isGenerating = false
                }
                return
            }
            let started = Date()
            let stream = runtime.run(request)
            do {
                for try await event in stream {
                    if Task.isCancelled { break }
                    await self.handle(event, started: started, request: request)
                }
            } catch let error as LocallyError {
                await MainActor.run { self.lastError = error.userMessage }
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
            await MainActor.run {
                self.isGenerating = false
                self.phase = nil
            }
        }
    }

    func cancel() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
        phase = nil
    }

    private func handle(_ event: AIEvent, started: Date, request: AIRequest) async {
        switch event {
        case .preparing(let phase):
            self.phase = phase
        case .progress(let fraction, phase: let phase):
            self.progress = fraction
            if let phase { self.phase = phase }
        case .image(let data):
            self.images.append(data)
        case .completed(let result):
            self.lastSeconds = Date().timeIntervalSince(started)
            self.lastSeedUsed = request.parameters.seed.map { UInt32(truncatingIfNeeded: $0) }
            if result.artifacts.isEmpty && images.isEmpty {
                self.lastError = String(localized: "imagegen.error.empty",
                                        table: "ImageGeneration")
            }
        case .failed(let error):
            self.lastError = error.userMessage
        default:
            break
        }
    }
}
