import Foundation
import LocallyCore
import LocallyDevice
import LocallyRuntime

/// Text-generation runtime for MLX-format models (safetensors + config.json),
/// backed by ml-explore/mlx-swift-lm 3.31.4 on Apple platforms. The whole
/// runtime is compiled out when MLXLLM is unavailable (Linux builds of the
/// package, old SDKs); the router then falls back to GGUF or reports the
/// model unsupported. Only compiled on iOS — the Metal GPU does not exist
/// elsewhere.
#if canImport(MLXLLM) && canImport(UIKit)
import MLX
import MLXLLM
import MLXLMCommon
import MLXRandom
import Tokenizers
import UIKit

/// Loads a swift-transformers tokenizer from a local directory. The directory
/// holds tokenizer_config.json / tokenizer.json installed alongside the
/// weights, so no network access ever occurs.
struct TransformersTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TransformersTokenizerAdapter(
            upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

/// Bridges swift-transformers `Tokenizers.Tokenizer` onto the
/// `MLXLMCommon.Tokenizer` protocol.
struct TransformersTokenizerAdapter: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        // swift-transformers accepts tool specs as JSON dictionaries; the
        // playground never passes tools, so this stays a passthrough.
        try upstream.applyChatTemplate(
            messages: messages, tools: tools, additionalContext: additionalContext)
    }
}
#endif

/// AIRuntime over MLX for text models in MLX format. One model is loaded at a
/// time per instance; GPU cache and memory limits are set from the device
/// budget before load. A memory warning unloads the model immediately.
public final class MLXRuntime: ModelCompatibleRuntime, @unchecked Sendable {
    public let kind: RuntimeKind = .mlx

    /// `true` when the MLXLLM library is compiled into the build.
    public static var isLibraryLinked: Bool {
        #if canImport(MLXLLM) && canImport(UIKit)
        return true
        #else
        return false
        #endif
    }

    /// Architectures (config.json `model_type`) MLXLLM 3.31.4 can instantiate.
    /// Source: mlx-swift-lm 3.31.4, Libraries/MLXLLM/LLMModelFactory.swift,
    /// `LLMTypeRegistry.shared` creators map.
    public static let knownModelTypes: Set<String> = [
        "mistral", "mixtral", "llama", "phi", "phi3", "phimoe",
        "gemma", "gemma2", "gemma3", "gemma3_text", "gemma3n",
        "gemma4", "gemma4_unified", "gemma4_text",
        "qwen2", "qwen3", "qwen3_moe", "qwen3_next",
        "qwen3_5", "qwen3_5_moe", "qwen3_5_text",
        "minicpm", "starcoder2", "cohere", "openelm", "internlm2",
        "deepseek_v3", "granite", "granitemoehybrid", "mimo",
        "mimo_v2_flash", "minimax", "glm4", "glm4_moe", "glm4_moe_lite",
        "acereason", "falcon_h1", "bitnet", "smollm3", "ernie4_5",
        "lfm2", "baichuan_m1", "exaone4", "gpt_oss", "lille-130m",
        "olmoe", "olmo2", "olmo3", "bailing_moe", "lfm2_moe",
        "nanochat", "nemotron_h", "afmoe", "jamba", "mamba2",
        "mistral3", "apertus", "nemotron_labs_diffusion",
    ]

    #if canImport(MLXLLM) && canImport(UIKit)
    private actor LoadState {
        var container: ModelContainer?
        var loadTime: TimeInterval = 0
        var peakMemoryAtLoad: Int64 = 0

        func store(_ container: ModelContainer, loadTime: TimeInterval, peakMemory: Int64) {
            self.container = container
            self.loadTime = loadTime
            self.peakMemoryAtLoad = peakMemory
        }
        func clear() {
            container = nil
            loadTime = 0
            peakMemoryAtLoad = 0
        }
        func current() -> (ModelContainer, TimeInterval, Int64)? {
            guard let container else { return nil }
            return (container, loadTime, peakMemoryAtLoad)
        }
    }
    private let state = LoadState()

    /// Non-Sendable observer token, boxed so the runtime stays Sendable.
    private final class ObserverBox: @unchecked Sendable {
        var token: NSObjectProtocol?
    }
    private let observerBox = ObserverBox()

    /// Fixed cap for MLX's Metal buffer cache. 64 MB is enough to keep the
    /// steady-state decode loop from re-allocating its small temporaries
    /// every token, but small enough that a memory warning isn't a cached
    /// GPU buffer the allocator refuses to release. See DECISIONS.md.
    public static let cacheLimitBytes = 64 * 1024 * 1024
    #endif

    public init() {
        #if canImport(MLXLLM) && canImport(UIKit)
        observerBox.token = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.unload() }
        }
        #endif
    }

    deinit {
        #if canImport(MLXLLM) && canImport(UIKit)
        if let token = observerBox.token {
            NotificationCenter.default.removeObserver(token)
        }
        #endif
    }

    /// Architecture string from a local config.json without loading weights;
    /// used so runtime overrides for MLX format models can be checked even
    /// when the descriptor snapshot has no architecture recorded.
    public static func modelType(inDirectory path: String) -> String? {
        let url = URL(fileURLWithPath: path).appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["model_type"] as? String else { return nil }
        return type
    }

    // MARK: - Compatibility

    public func compatibility(with model: ModelDescriptor,
                              architectureOverride: String? = nil) -> CompatibilityRating {
        let architecture = model.architecture ?? architectureOverride
        return compatibility(
            modality: model.modality, formats: model.formats, architecture: architecture)
    }

    public func compatibility(with model: ModelDescriptor,
                              on device: DeviceCapabilities) -> CompatibilityRating {
        guard Self.isLibraryLinked else {
            return .unsupported(reason: "MLX libraries are not linked into this build")
        }
        guard device.metalAvailable else {
            return .unsupported(reason: "MLX requires a Metal device; unavailable on Simulator")
        }
        return compatibility(
            modality: model.modality, formats: model.formats,
            architecture: model.architecture)
    }

    private func compatibility(modality: ModelModality, formats: [ModelFormat],
                               architecture: String?) -> CompatibilityRating {
        guard Self.isLibraryLinked else {
            return .unsupported(reason: "MLX libraries are not linked into this build")
        }
        guard modality == .text || modality == .unknown else {
            return .unsupported(reason: "MLX runtime handles text generation; \(modality.rawValue) is not supported here")
        }
        guard formats.contains(.mlx) else {
            return .unsupported(reason: "model is not in MLX format")
        }
        if let architecture {
            let type = architecture.lowercased()
            if Self.knownModelTypes.contains(type) { return .supported }
            return .risky(reason: "model_type '\(architecture)' is not in the MLXLLM 3.31.4 supported list")
        }
        return .risky(reason: "model architecture unknown; MLX may not run it")
    }

    public func isSupported(on device: DeviceCapabilities) -> Bool {
        Self.isLibraryLinked && device.metalAvailable
    }

    // MARK: - Lifecycle

    /// Load an installed MLX model from its on-disk directory. No network:
    /// the downloader path of the factory is never used.
    public func load(_ model: ModelDescriptor) async throws {
        #if canImport(MLXLLM) && canImport(UIKit)
        guard let path = model.metadata["localDirectory"],
              !path.isEmpty else {
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
        // loading (same heuristic the compatibility engine uses), and cap
        // the Metal buffer cache at a small fixed size.
        let physical = ProcessInfo.processInfo.physicalMemory
        MLX.Memory.memoryLimit = Int(MemoryBudget.safeAIBudget(
            physicalMemory: physical, availableEstimate: physical))
        MLX.Memory.cacheLimit = Self.cacheLimitBytes

        let start = ContinuousClock.now
        do {
            let container = try await LLMModelFactory.shared.loadContainer(
                from: directory,
                using: TransformersTokenizerLoader())
            await state.store(
                container,
                loadTime: start.duration(to: .now).magnitudeSeconds,
                peakMemory: Int64(MLX.Memory.peakMemory))
        } catch let error as LocallyError {
            throw error
        } catch {
            throw LocallyError.inferenceFailed(
                userMessage: "The MLX model couldn't be loaded.",
                technicalDetail: "\(error)")
        }
        #else
        throw LocallyError.runtimeUnavailable(
            userMessage: "MLX inference is not available in this build.",
            technicalDetail: "MLXLLM not linked (requires an Apple GPU build)")
        #endif
    }

    public func unload() async {
        #if canImport(MLXLLM) && canImport(UIKit)
        await state.clear()
        MLX.Memory.clearCache()
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

    private func execute(request: AIRequest,
                         continuation: AsyncThrowingStream<AIEvent, Error>.Continuation) async {
        #if canImport(MLXLLM) && canImport(UIKit)
        continuation.yield(.started(requestID: request.id))
        let start = ContinuousClock.now
        do {
            guard let (container, loadTime, peakAtLoad) = await state.current() else {
                throw LocallyError.runtimeUnavailable(
                    userMessage: "No MLX model is loaded.",
                    technicalDetail: "run() before load()")
            }

            let session = sessionFor(request: request)
            let parameters = GenerateParameters(
                maxTokens: request.parameters.maxTokens,
                maxKVSize: request.parameters.contextLength,
                temperature: Float(request.parameters.temperature),
                topP: Float(request.parameters.topP),
                topK: request.parameters.topK ?? 0,
                repetitionPenalty: nil,
                seed: request.parameters.seed)
            let extraStopStrings = Set(request.parameters.stop)

            /// Sendable snapshot of what we take out of the container's
            /// serial context: the generation stream only (MLXArray never
            /// crosses the actor boundary).
            struct RunOutput: Sendable {
                var stream: AsyncStream<MLXLMCommon.Generation>
            }

            let output: RunOutput = try await container.perform { context in
                var messages: [Chat.Message] = []
                if let systemPrompt = session.systemPrompt,
                   !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    messages.append(.system(systemPrompt))
                }
                for turn in session.turns {
                    switch turn.role {
                    case .system:
                        continue  // system prompt handled by the instructions slot
                    case .user:
                        messages.append(.user(turn.content))
                    case .assistant:
                        messages.append(.assistant(turn.content))
                    }
                }
                if messages.isEmpty {
                    messages.append(.user(""))
                }
                var configuration = context.configuration
                configuration.extraEOSTokens.formUnion(extraStopStrings)
                let promptTokens = try context.tokenizer.applyChatTemplate(
                    messages: messages.map {
                        ["role": $0.role.rawValue, "content": $0.content]
                    })
                let input = LMInput(tokens: MLXArray(promptTokens))
                var effectiveContext = context
                effectiveContext.configuration = configuration
                let stream = try MLXLMCommon.generate(
                    input: input, parameters: parameters, context: effectiveContext)
                return RunOutput(stream: stream)
            }

            var generated = ""
            var info: GenerateCompletionInfo?
            streamLoop: for await generation in output.stream {
                if Task.isCancelled {
                    continuation.yield(.failed(.cancelled))
                    continuation.finish()
                    return
                }
                switch generation {
                case .chunk(let text):
                    generated += text
                    continuation.yield(.token(text))
                    if request.parameters.stop.contains(where: { generated.hasSuffix($0) }) {
                        break streamLoop
                    }
                case .info(let completionInfo):
                    info = completionInfo
                case .toolCall:
                    continue  // tool calls are out of scope for the playground
                }
            }

            let elapsed = start.duration(to: .now).magnitudeSeconds
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
                userMessage: "Text generation failed.", technicalDetail: "\(error)")))
            continuation.finish()
        }
        #else
        continuation.yield(.failed(.runtimeUnavailable(
            userMessage: "MLX inference is not available in this build.",
            technicalDetail: "MLXLLM not linked")))
        continuation.finish()
        #endif
    }

    private func sessionFor(request: AIRequest) -> TextGenerationSession {
        switch request.input {
        case .chat(let messages):
            var system: String?
            var turns: [ChatTurn] = []
            for message in messages {
                switch message.role {
                case .system: system = message.content
                case .user: turns.append(ChatTurn(role: .user, content: message.content))
                case .assistant: turns.append(ChatTurn(role: .assistant, content: message.content))
                case .tool: turns.append(ChatTurn(role: .user, content: message.content))
                }
            }
            return TextGenerationSession(systemPrompt: system, turns: turns)
        case .text(let text):
            return TextGenerationSession(turns: [ChatTurn(role: .user, content: text)])
        default:
            return TextGenerationSession(turns: [ChatTurn(role: .user, content: "")])
        }
    }
}

/// Duration → seconds, shared with GGUFRuntime (private there, so the
/// extension is scoped here to avoid touching the shared file).
private extension Duration {
    var magnitudeSeconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
