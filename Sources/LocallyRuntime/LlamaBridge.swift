import Foundation
import LocallyCore

#if canImport(CLlama)
import CLlama

/// Thin Swift wrapper over the llama.cpp C API (pinned tag: v0.5.0, see
/// DEPENDENCIES.md). All decode work runs on this actor, off the main actor.
/// Nothing here is ever called on a loaded invalid model: GGUFParser
/// validates the file before `LlamaModel(path:)` is attempted.
actor LlamaBridge {

    /// Process-wide backend lifecycle. llama_backend_init is not
    /// reference-counted, so gate it behind a one-time flag.
    private static let backendLock = NSLock()
    private static var backendStarted = false

    static func ensureBackend() {
        backendLock.lock()
        defer { backendLock.unlock() }
        if !backendStarted {
            llama_backend_init()
            backendStarted = true
        }
    }

    private(set) var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var modelContextLength: Int32 = 0

    /// Load a validated GGUF file. `nGPULayers` = -1 (all) on Apple/Metal,
    /// 0 (CPU) on Linux.
    func loadModel(path: String) throws {
        Self.ensureBackend()
        var params = llama_model_default_params()
        #if os(iOS) || os(macOS) || os(tvOS) || os(visionOS) || os(watchOS)
        params.n_gpu_layers = -1
        #else
        params.n_gpu_layers = 0
        #endif
        guard let loaded = path.withCString({ llama_model_load_from_file($0, params) }) else {
            throw LocallyError.inferenceFailed(
                userMessage: "The model file could not be loaded.",
                technicalDetail: "llama_model_load_from_file returned nil for \(path)")
        }
        model = loaded
        vocab = llama_model_get_vocab(loaded)
        modelContextLength = llama_model_n_ctx_train(loaded)
    }

    var contextLength: Int { Int(modelContextLength) }

    /// The model's embedded chat template, or nil when none is stored.
    var chatTemplate: String? {
        guard let model else { return nil }
        guard let ptr = llama_model_chat_template(model, nil) else { return nil }
        return String(cString: ptr)
    }

    /// Render chat messages through llama's template engine when the model
    /// ships a supported template; otherwise through the shared ChatML
    /// fallback renderer.
    func renderPrompt(session: TextGenerationSession) -> String {
        if let template = chatTemplate,
           let rendered = renderWithLlamaTemplate(template: template, session: session) {
            return rendered
        }
        if let rendered = session.render(template: chatTemplate) { return rendered }
        return session.renderChatML()
    }

    private func renderWithLlamaTemplate(template: String, session: TextGenerationSession) -> String? {
        var messages: [AIInput.ChatMessage] = []
        if let system = session.systemPrompt, !system.isEmpty {
            messages.append(AIInput.ChatMessage(role: .system, content: system))
        }
        for turn in session.turns {
            let role: AIInput.ChatMessage.Role
            switch turn.role {
            case .system: role = .system
            case .user: role = .user
            case .assistant: role = .assistant
            }
            messages.append(AIInput.ChatMessage(role: role, content: turn.content))
        }
        // Build the C message array. llama_chat_apply_template returns < 0
        // when the template is not one of the supported built-ins.
        var cStrings: [(role: [CChar], content: [CChar])] = messages.map {
            (Array($0.role.rawValue.utf8CString), Array($0.content.utf8CString))
        }
        var chat = [llama_chat_message](repeating: llama_chat_message(role: nil, content: nil),
                                        count: cStrings.count)
        for i in cStrings.indices {
            cStrings[i].role.withUnsafeBufferPointer { r in
                cStrings[i].content.withUnsafeBufferPointer { c in
                    chat[i] = llama_chat_message(role: r.baseAddress, content: c.baseAddress)
                }
            }
        }
        var size = template.withCString { tmpl in
            chat.withUnsafeBufferPointer { buf in
                llama_chat_apply_template(tmpl, buf.baseAddress, buf.count, true, nil, 0)
            }
        }
        guard size >= 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        size = template.withCString { tmpl in
            chat.withUnsafeBufferPointer { chatBuf in
                buffer.withUnsafeMutableBufferPointer { out in
                    llama_chat_apply_template(tmpl, chatBuf.baseAddress, chatBuf.count,
                                              true, out.baseAddress, Int32(out.count))
                }
            }
        }
        guard size >= 0 else { return nil }
        return String(decoding: buffer.prefix(Int(size)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Create a fresh decode context. Caller must `endContext()` when done.
    func beginContext(maxContext: Int?) throws {
        guard let model else {
            throw LocallyError.runtimeUnavailable(
                userMessage: "No model is loaded.", technicalDetail: "beginContext without model")
        }
        endContext()
        var params = llama_context_default_params()
        let requested = maxContext ?? contextLength
        params.n_ctx = UInt32(clamping: max(requested, 8))
        params.n_batch = min(params.n_ctx, 512)
        params.n_threads = Int32(ProcessInfo.processInfo.processorCount)
        params.n_threads_batch = params.n_threads
        guard let ctx = llama_init_from_model(model, params) else {
            throw LocallyError.inferenceFailed(
                userMessage: "Could not create an inference context.",
                technicalDetail: "llama_init_from_model returned nil")
        }
        context = ctx
    }

    func endContext() {
        if let context { llama_free(context) }
        context = nil
    }

    func tokenize(_ text: String, addSpecial: Bool) throws -> [llama_token] {
        guard let vocab else {
            throw LocallyError.runtimeUnavailable(
                userMessage: "No model is loaded.", technicalDetail: "tokenize without model")
        }
        let utf8 = Array(text.utf8)
        let capacity = utf8.count + 8
        var tokens = [llama_token](repeating: 0, count: capacity)
        let n = utf8.withUnsafeBufferPointer { textBuf in
            tokens.withUnsafeMutableBufferPointer { tokBuf in
                llama_tokenize(vocab, textBuf.baseAddress, Int32(utf8.count),
                               tokBuf.baseAddress, Int32(capacity), addSpecial, true)
            }
        }
        guard n >= 0 else {
            throw LocallyError.inferenceFailed(
                userMessage: "The prompt could not be tokenized.",
                technicalDetail: "llama_tokenize overflow for \(utf8.count) bytes")
        }
        return Array(tokens.prefix(Int(n)))
    }

    func decode(tokens: [llama_token]) throws {
        guard let context else {
            throw LocallyError.runtimeUnavailable(
                userMessage: "No context is active.", technicalDetail: "decode without context")
        }
        var mutable = tokens
        let rc = mutable.withUnsafeMutableBufferPointer { buf in
            llama_decode(context, llama_batch_get_one(buf.baseAddress, Int32(buf.count)))
        }
        guard rc == 0 else {
            throw LocallyError.inferenceFailed(
                userMessage: "The model failed while processing the prompt.",
                technicalDetail: "llama_decode returned \(rc)")
        }
    }

    /// Sample the next token with the given chain parameters. Greedy when
    /// temperature == 0.
    func sampleNext(temperature: Double, topP: Double, topK: Int?, seed: UInt64?) throws -> llama_token {
        guard let context else {
            throw LocallyError.runtimeUnavailable(
                userMessage: "No context is active.", technicalDetail: "sample without context")
        }
        let chainParams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(chainParams) else {
            throw LocallyError.inferenceFailed(
                userMessage: "Could not initialize sampling.",
                technicalDetail: "llama_sampler_chain_init returned nil")
        }
        defer { llama_sampler_free(chain) }
        if temperature <= 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            if let topK, topK > 0 { llama_sampler_chain_add(chain, llama_sampler_init_top_k(Int32(topK))) }
            if topP < 1.0 { llama_sampler_chain_add(chain, llama_sampler_init_top_p(Float(topP), 1)) }
            llama_sampler_chain_add(chain, llama_sampler_init_temp(Float(temperature)))
            let seed32 = seed.map { UInt32(truncatingIfNeeded: $0) } ?? UInt32(LLAMA_DEFAULT_SEED)
            llama_sampler_chain_add(chain, llama_sampler_init_dist(seed32))
        }
        return llama_sampler_sample(chain, context, -1)
    }

    func isEndOfGeneration(_ token: llama_token) -> Bool {
        guard let vocab else { return true }
        return llama_vocab_is_eog(vocab, token)
    }

    /// Raw bytes of a token piece. Callers must buffer partial UTF-8
    /// sequences across tokens (see PieceAssembler).
    func tokenPiece(_ token: llama_token) -> [UInt8] {
        guard let vocab else { return [] }
        var buffer = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if n < 0 {
            buffer = [CChar](repeating: 0, count: Int(-n) + 1)
            n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        guard n > 0 else { return [] }
        return buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }
    }

    func usedContextTokens() -> Int {
        guard let context else { return 0 }
        return Int(llama_memory_seq_pos_max(llama_get_memory(context), 0)) + 1
    }

    func unload() {
        endContext()
        if let model { llama_model_free(model) }
        model = nil
        vocab = nil
    }
}

/// Accumulates raw token-piece bytes and emits only complete UTF-8 text, so
/// multi-byte characters split across tokens never produce mojibake.
struct PieceAssembler {
    private var pending: [UInt8] = []

    mutating func append(_ piece: [UInt8]) -> String {
        pending.append(contentsOf: piece)
        // Emit the longest valid-UTF-8 prefix that does not end inside a
        // multi-byte sequence; keep the incomplete tail for the next piece.
        let maxKeep = 3 // longest UTF-8 sequence minus one
        let limit = max(0, pending.count - maxKeep)
        var decodable = limit
        while decodable > 0 {
            if let text = String(bytes: pending.prefix(decodable), encoding: .utf8) {
                pending.removeFirst(decodable)
                return text
            }
            decodable -= 1
        }
        if limit == 0, pending.count > maxKeep {
            // Un-decodable garbage (should not happen with a real vocab):
            // drop it rather than grow without bound.
            pending.removeAll(keepingCapacity: true)
        }
        return ""
    }

    mutating func flush() -> String {
        let text = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return text
    }
}
#endif
