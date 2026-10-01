import Foundation
import LocallyCore

/// Text-generation runtime for GGUF models, backed by llama.cpp when the
/// library is linked (Apple: xcframework binary target; Linux: the
/// scripts/build-llama-linux.sh install). Without llama linked, the runtime
/// still parses GGUF headers for compatibility checks but reports itself
/// unavailable for inference, honestly.
public final class GGUFRuntime: ModelCompatibleRuntime, @unchecked Sendable {
    public let kind: RuntimeKind = .gguf

    /// Architectures the pinned llama.cpp (v0.5.0) knows how to run.
    /// Source: src/llama-arch.cpp LLM_ARCH_NAMES of the pinned tag.
    public static let knownArchitectures: Set<String> = [
        "llama", "llama4", "llama-embed", "mistral3", "mistral4",
        "gemma", "gemma2", "gemma3", "gemma3n", "gemma4", "gemma4-assistant",
        "gemma-embedding", "phi2", "phi3", "phimoe",
        "qwen", "qwen2", "qwen2moe", "qwen2vl", "qwen3", "qwen3moe", "qwen3vl",
        "qwen3vlmoe", "qwen3next", "qwen35", "qwen35moe", "qwen4exp",
        "gpt2", "gptj", "gptneox", "gpt-oss", "mpt", "baichuan", "stablelm",
        "starcoder", "starcoder2", "falcon", "falcon-h1", "bloom", "orion",
        "refact", "deepseek", "deepseek2", "deepseek2-ocr", "deepseek32",
        "deepseek4", "internlm2", "minicpm", "minicpm3", "command-r",
        "cohere2", "cohere2moe", "dbrx", "jamba", "mamba", "mamba2",
        "rwkv6", "rwkv6qwen2", "rwkv7", "arwkv7", "exaone", "exaone-moe",
        "exaone4", "granite", "granitehybrid", "granitemoe", "graniteswitch",
        "granite_swa", "olmo", "olmo2", "olmoe", "openelm", "arctic",
        "bert", "nomic-bert", "nomic-bert-moe", "modern-bert", "neo-bert",
        "jina-bert-v2", "jina-bert-v3", "eurobert", "chatglm", "glm4",
        "glm4moe", "glm-dsa", "ernie4_5", "ernie4_5-moe", "hunyuan-dense",
        "hunyuan-moe", "hunyuan_vl", "smollm3", "smallthinker", "plamo",
        "plamo2", "plamo3", "dots1", "dots3note", "seed_oss", "lfm2",
        "lfm2moe", "apertus", "bitnet", "chameleon", "clip", "cogvlm",
        "codeshell", "deci", "jais", "jais2", "xverse", "t5", "t5encoder",
        "mellum", "minimax-01", "minimax-m2", "minimax-m3", "nemotron",
        "nemotron_h", "nemotron_h_moe", "afmoe", "arcee", "bailingmoe",
        "bailingmoe2", "bailingmoe3", "dream", "llada", "llada-moe", "grok",
        "grovemoe", "hrm_text", "hy_v3", "hy_v4", "kimi-k3", "kimi-linear",
        "laguna", "maincoder", "maple", "mimo2", "nanbeige", "paddleocr",
        "pangu-embedded", "rnd1", "step35", "spark2_5", "talkie",
        "wavtokenizer-dec", "dflash", "eagle3", "muse-glimmer", "pockettts",
        "qwen3tts",
    ]

    /// `true` when the llama.cpp C library is linked into the process.
    public static var isLlamaLinked: Bool {
        #if canImport(CLlama) || canImport(llama)
        return true
        #else
        return false
        #endif
    }

    private let parser = GGUFParser()

    #if canImport(CLlama) || canImport(llama)
    private let bridge = LlamaBridge()
    #endif

    /// Mutable load state, guarded by the actor so async contexts stay safe.
    private actor LoadState {
        var summary: GGUFModelSummary?
        var loadTime: TimeInterval = 0
        func store(_ summary: GGUFModelSummary, _ loadTime: TimeInterval) {
            self.summary = summary
            self.loadTime = loadTime
        }
        func clear() {
            summary = nil
            loadTime = 0
        }
        func current() -> (GGUFModelSummary, TimeInterval)? {
            guard let summary else { return nil }
            return (summary, loadTime)
        }
    }
    private let state = LoadState()

    public init() {}

    // MARK: - Compatibility

    public func compatibility(with model: ModelDescriptor,
                              on device: DeviceCapabilities) -> CompatibilityRating {
        guard model.modality == .text || model.modality == .unknown else {
            return .unsupported(reason: "GGUF runtime handles text generation; \(model.modality.rawValue) is not supported here")
        }
        guard model.formats.isEmpty || model.formats.contains(.gguf) else {
            return .unsupported(reason: "model is not in GGUF format")
        }
        if !Self.isLlamaLinked {
            return .unsupported(reason: "llama.cpp is not linked into this build (run scripts/build-llama-linux.sh, or use the Apple xcframework)")
        }
        if let arch = model.architecture {
            if Self.knownArchitectures.contains(arch) { return .supported }
            return .risky(reason: "architecture '\(arch)' is not in the llama.cpp v0.5.0 supported list")
        }
        return .risky(reason: "model architecture unknown; llama.cpp may not run it")
    }

    public func isSupported(on device: DeviceCapabilities) -> Bool {
        Self.isLlamaLinked
    }

    // MARK: - Lifecycle

    /// Validate the GGUF header, then (when llama is linked) load the model.
    /// A corrupted or hostile file fails in the parser — llama.cpp never
    /// touches it.
    public func load(_ model: ModelDescriptor) async throws {
        guard let path = model.metadata["localPath"] ?? model.requiredFiles.first?.path,
              !path.isEmpty else {
            throw LocallyError.modelNotFound(
                userMessage: "The model file is not available on disk.",
                technicalDetail: "no localPath in metadata and no requiredFiles for \(model.repoID)")
        }
        let url = URL(fileURLWithPath: path)
        let header: GGUFParser.Header
        do {
            header = try parser.parse(fileAt: url)
        } catch let error as GGUFParser.ParseError {
            throw LocallyError.unknown(
                userMessage: "The model file is invalid or corrupted.",
                technicalDetail: "GGUF parse failed: \(describe(error))")
        }
        let summary = GGUFModelSummary(header: header)

        #if canImport(CLlama) || canImport(llama)
        let start = ContinuousClock.now
        try await bridge.loadModel(path: url.path)
        await state.store(summary, start.duration(to: .now).magnitudeSeconds)
        #else
        throw LocallyError.runtimeUnavailable(
            userMessage: "GGUF inference is not available in this build.",
            technicalDetail: "llama.cpp not linked; header parsed OK (arch \(summary.architecture ?? "unknown"), \(summary.parameterCount) params)")
        #endif
    }

    public func unload() async {
        #if canImport(CLlama) || canImport(llama)
        await bridge.unload()
        #endif
        await state.clear()
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
        #if canImport(CLlama) || canImport(llama)
        continuation.yield(.started(requestID: request.id))
        let start = ContinuousClock.now
        do {
            guard let (_, loadTime) = await state.current() else {
                throw LocallyError.runtimeUnavailable(
                    userMessage: "No GGUF model is loaded.",
                    technicalDetail: "run() before load()")
            }

            let session = sessionFor(request: request)
            let maxTokens = max(request.parameters.maxTokens, 1)

            try await bridge.beginContext(maxContext: request.parameters.contextLength)
            let nCtx = await bridge.contextLength

            let prompt = await bridge.renderPrompt(session: session)
            let promptTokens = try await bridge.tokenize(prompt, addSpecial: false)

            // Context overflow policy: truncate the generation budget to fit;
            // fail honestly when the prompt alone overflows the window.
            if promptTokens.count >= nCtx {
                throw LocallyError.inferenceFailed(
                    userMessage: "The conversation is too long for this model's context window.",
                    technicalDetail: "prompt \(promptTokens.count) tokens >= context \(nCtx)")
            }
            let budget = min(maxTokens, nCtx - promptTokens.count)

            try await bridge.decode(tokens: promptTokens)

            var assembler = PieceAssembler()
            var generated = ""
            var generatedCount = 0
            var ttft: TimeInterval?
            let genStart = ContinuousClock.now

            for _ in 0..<budget {
                if Task.isCancelled {
                    continuation.yield(.failed(.cancelled))
                    continuation.finish()
                    await bridge.endContext()
                    return
                }
                let token = try await bridge.sampleNext(
                    temperature: request.parameters.temperature,
                    topP: request.parameters.topP,
                    topK: request.parameters.topK,
                    seed: request.parameters.seed)
                if await bridge.isEndOfGeneration(token) { break }
                if ttft == nil { ttft = start.duration(to: .now).magnitudeSeconds }
                generatedCount += 1
                let piece = await bridge.tokenPiece(token)
                let text = assembler.append(piece)
                if !text.isEmpty {
                    generated += text
                    continuation.yield(.token(text))
                    if request.parameters.stop.contains(where: { generated.hasSuffix($0) }) { break }
                }
                try await bridge.decode(tokens: [token])
            }
            let remainder = assembler.flush()
            if !remainder.isEmpty {
                generated += remainder
                continuation.yield(.token(remainder))
            }
            await bridge.endContext()

            let genSeconds = max(genStart.duration(to: .now).magnitudeSeconds, 0.000_001)
            let metadata = InferenceMetadata(
                loadTime: loadTime,
                ttft: ttft ?? start.duration(to: .now).magnitudeSeconds,
                tokensPerSecond: generatedCount > 0 ? Double(generatedCount) / genSeconds : nil,
                generatedTokens: generatedCount)
            continuation.yield(.completed(result: AIResult(
                requestID: request.id, text: generated, metadata: metadata)))
            continuation.finish()
        } catch let error as LocallyError {
            await bridge.endContext()
            continuation.yield(.failed(error))
            continuation.finish()
        } catch {
            await bridge.endContext()
            continuation.yield(.failed(.inferenceFailed(
                userMessage: "Text generation failed.", technicalDetail: "\(error)")))
            continuation.finish()
        }
        #else
        continuation.yield(.failed(.runtimeUnavailable(
            userMessage: "GGUF inference is not available in this build.",
            technicalDetail: "llama.cpp not linked")))
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

    private func describe(_ error: GGUFParser.ParseError) -> String {
        switch error {
        case .truncated: return "file is truncated or corrupt"
        case .badMagic: return "not a GGUF file (bad magic)"
        case .unsupportedVersion(let v): return "unsupported GGUF version \(v)"
        case .limitExceeded(let what): return "implausible header value: \(what)"
        case .invalidValue(let what): return "invalid header value: \(what)"
        }
    }
}

extension Duration {
    var magnitudeSeconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
