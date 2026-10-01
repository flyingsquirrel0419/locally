import Foundation
import LocallyCore
import LocallyRuntime
import Observation

/// Drives the chat playground: owns the conversation, streams runtime
/// events, and exposes the metrics the footer shows. Nothing here is
/// simulated; every value comes from the runtime's events.
@Observable
@MainActor
final class ChatViewModel {
    struct Message: Identifiable {
        let id = UUID()
        let role: Role
        var content: String
        enum Role { case user, assistant }
    }

    struct Metrics {
        var loadTime: TimeInterval?
        var ttft: TimeInterval?
        var tokensPerSecond: Double?
        var generatedTokens: Int?
    }

    private(set) var messages: [Message] = []
    private(set) var streamingMessageID: UUID?
    private(set) var metrics = Metrics()
    private(set) var lastError: String?

    var input = ""
    var isGenerating: Bool { generationTask != nil }

    // Generation controls.
    var systemPrompt = ""
    var temperature = 0.7
    var topP = 0.95
    var topK: Int?
    var maxTokens = 512
    var contextLength: Int?

    private let model: ModelDescriptor
    private let router: RuntimeRouter
    private let device: DeviceCapabilities
    /// Called with each completed run's measured metadata so the library can
    /// record it (drives the "Measured" speed label in compatibility).
    private let onInferenceCompleted: (@Sendable (InferenceMetadata) -> Void)?
    private var runtime: (any ModelCompatibleRuntime)?
    private var generationTask: Task<Void, Never>?
    private var loadAttempted = false

    init(model: ModelDescriptor, router: RuntimeRouter, device: DeviceCapabilities,
         onInferenceCompleted: (@Sendable (InferenceMetadata) -> Void)? = nil) {
        self.model = model
        self.router = router
        self.device = device
        self.onInferenceCompleted = onInferenceCompleted
    }

    /// Decision for the current model, so the container can show an honest
    /// state (supported / risky / unsupported) before anything runs.
    var decision: RuntimeRouter.Decision {
        router.decide(for: model, on: device)
    }

    var isRunnable: Bool { decision.isRunnable }

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
            lastError = error.localizedDescription
        }
    }

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating, let runtime else { return }
        let gate = ResourcePolicyObserver.shared.gateHeavyInference()
        guard gate.allowed else {
            lastError = gate.reason
            return
        }
        input = ""
        lastError = nil
        messages.append(Message(role: .user, content: text))
        let assistant = Message(role: .assistant, content: "")
        messages.append(assistant)
        streamingMessageID = assistant.id

        var chatMessages: [AIInput.ChatMessage] = []
        if !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chatMessages.append(.init(role: .system, content: systemPrompt))
        }
        chatMessages += messages.dropLast().map {
            $0.role == .user
                ? .init(role: .user, content: $0.content)
                : .init(role: .assistant, content: $0.content)
        }

        let request = AIRequest(
            model: model,
            input: .chat(chatMessages),
            parameters: GenerationParameters(
                temperature: temperature,
                topP: topP,
                topK: topK,
                maxTokens: maxTokens,
                contextLength: contextLength,
                stop: []
            )
        )

        ResourcePolicyObserver.shared.setActivity(.textGeneration)
        generationTask = Task { [weak self] in
            guard let self else { return }
            let stream = runtime.run(request)
            do {
                for try await event in stream {
                    if Task.isCancelled { break }
                    self.handle(event)
                }
            } catch {
                if !Task.isCancelled {
                    self.failStreaming(with: error.localizedDescription)
                }
            }
            self.finishGeneration()
        }
    }

    func stop() {
        generationTask?.cancel()
    }

    /// App-wide resource policy entry point: cancel the active generation
    /// and surface the reason. Called by ResourcePolicyObserver via the
    /// registry's handler when memory/thermal pressure demands a stop.
    func stopForResourcePolicy(reason: String) {
        guard isGenerating else { return }
        generationTask?.cancel()
        failStreaming(with: reason)
    }

    func clearConversation() {
        guard !isGenerating else { return }
        messages = []
        metrics = Metrics()
        lastError = nil
    }

    private func handle(_ event: AIEvent) {
        switch event {
        case .token(let piece):
            appendToStreaming(piece)
        case .partialText(let text):
            setStreaming(text)
        case .completed(let result):
            if let text = result.text { setStreaming(text) }
            metrics = Metrics(
                loadTime: result.metadata.loadTime,
                ttft: result.metadata.ttft,
                tokensPerSecond: result.metadata.tokensPerSecond,
                generatedTokens: result.metadata.generatedTokens
            )
            if result.metadata.tokensPerSecond != nil {
                onInferenceCompleted?(result.metadata)
            }
        case .failed(let error):
            failStreaming(with: error.userMessage)
        default:
            break
        }
    }

    private func appendToStreaming(_ piece: String) {
        guard let id = streamingMessageID,
              let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].content += piece
    }

    private func setStreaming(_ text: String) {
        guard let id = streamingMessageID,
              let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].content = text
    }

    private func failStreaming(with message: String) {
        lastError = message
        if let id = streamingMessageID,
           let index = messages.firstIndex(where: { $0.id == id }),
           messages[index].content.isEmpty {
            messages.remove(at: index)
        }
    }

    private func finishGeneration() {
        generationTask = nil
        streamingMessageID = nil
        ResourcePolicyObserver.shared.setActivity(.idle)
    }

    // Metrics formatting for the footer.
    static func formatSeconds(_ value: TimeInterval?) -> String {
        guard let value else { return "–" }
        return String(format: "%.2f s", value)
    }

    static func formatRate(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.1f", value)
    }
}
