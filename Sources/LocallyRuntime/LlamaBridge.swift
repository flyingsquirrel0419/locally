import Foundation
import LocallyCore

#if canImport(Darwin)
import Darwin
#endif
#if canImport(MachO)
// mach_vm_basic_info_data_t / MACH_VM_BASIC_INFO live in the MachO module
// on Apple SDKs (they are not visible via plain `import Darwin`).
import MachO
#endif

#if canImport(CLlama)
import CLlama
#elseif canImport(llama)
import llama
#endif

#if canImport(CLlama) || canImport(llama)

/// Thin Swift wrapper over the llama.cpp C API (pinned tag: v0.5.0, see
/// DEPENDENCIES.md). All decode work runs on this actor, off the main actor.
/// Nothing here is ever called on a loaded invalid model: GGUFParser
/// validates the file before `LlamaModel(path:)` is attempted.
actor LlamaBridge {

    /// Process-wide backend lifecycle. llama_backend_init is not
    /// reference-counted, so gate it behind a one-time flag.
    private static let backendLock = NSLock()
    // Protected by `backendLock`; nonisolated(unsafe) because Swift 6 strict
    // concurrency cannot see the NSLock guard.
    private nonisolated(unsafe) static var backendStarted = false

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
    /// Actual n_ctx of the live context (set in beginContext).
    private(set) var activeContextTokens: Int32 = 0
    /// Persistent sampler chain for the live context. Rebuilding the chain
    /// per token was the dominant Swift-side decode cost; create once per
    /// context and reconfigure in place.
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private var samplerConfig: (temperature: Double, topP: Double, topK: Int?, seed: UInt64?)?

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

    /// n_ctx of the currently active decode context (0 when none).
    var activeContextLength: Int { Int(activeContextTokens) }

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
        // Active (not logical) cores: matches llama-bench -t <cores> baselines
        // and respects cgroup / affinity limits on Linux.
        let threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount))
        params.n_threads = threads
        params.n_threads_batch = threads
        guard let ctx = llama_init_from_model(model, params) else {
            throw LocallyError.inferenceFailed(
                userMessage: "Could not create an inference context.",
                technicalDetail: "llama_init_from_model returned nil")
        }
        context = ctx
        activeContextTokens = Int32(params.n_ctx)
    }

    func endContext() {
        if let sampler { llama_sampler_free(sampler) }
        sampler = nil
        samplerConfig = nil
        if let context { llama_free(context) }
        context = nil
        activeContextTokens = 0
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

    /// Build (or rebuild when the config changed) the persistent sampler
    /// chain. Greedy when temperature == 0.
    private func ensureSampler(temperature: Double, topP: Double, topK: Int?,
                               seed: UInt64?) throws -> UnsafeMutablePointer<llama_sampler> {
        let config = (temperature: temperature, topP: topP, topK: topK, seed: seed)
        if let sampler, let existing = samplerConfig,
           existing.temperature == config.temperature, existing.topP == config.topP,
           existing.topK == config.topK, existing.seed == config.seed {
            return sampler
        }
        if let sampler { llama_sampler_free(sampler) }
        sampler = nil
        samplerConfig = nil
        let chainParams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(chainParams) else {
            throw LocallyError.inferenceFailed(
                userMessage: "Could not initialize sampling.",
                technicalDetail: "llama_sampler_chain_init returned nil")
        }
        if temperature <= 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            if let topK, topK > 0 { llama_sampler_chain_add(chain, llama_sampler_init_top_k(Int32(topK))) }
            if topP < 1.0 { llama_sampler_chain_add(chain, llama_sampler_init_top_p(Float(topP), 1)) }
            llama_sampler_chain_add(chain, llama_sampler_init_temp(Float(temperature)))
            let seed32 = seed.map { UInt32(truncatingIfNeeded: $0) } ?? UInt32(LLAMA_DEFAULT_SEED)
            llama_sampler_chain_add(chain, llama_sampler_init_dist(seed32))
        }
        sampler = chain
        samplerConfig = config
        return chain
    }

    /// Sample the next token from the current context state. Prefer
    /// `generateNext` in the decode loop — it avoids extra actor hops.
    func sampleNext(temperature: Double, topP: Double, topK: Int?, seed: UInt64?) throws -> llama_token {
        guard let context else {
            throw LocallyError.runtimeUnavailable(
                userMessage: "No context is active.", technicalDetail: "sample without context")
        }
        let chain = try ensureSampler(temperature: temperature, topP: topP, topK: topK, seed: seed)
        return llama_sampler_sample(chain, context, -1)
    }

    /// One decode step: sample from current logits, report EOG, decode the
    /// token back into the context (unless it ended generation), and return
    /// its raw piece bytes. Fused so each generated token costs one actor
    /// hop instead of four.
    func generateNext(temperature: Double, topP: Double, topK: Int?,
                      seed: UInt64?) throws -> (token: llama_token, piece: [UInt8], isEOG: Bool) {
        guard let context else {
            throw LocallyError.runtimeUnavailable(
                userMessage: "No context is active.", technicalDetail: "sample without context")
        }
        let chain = try ensureSampler(temperature: temperature, topP: topP, topK: topK, seed: seed)
        let token = llama_sampler_sample(chain, context, -1)
        if let vocab, llama_vocab_is_eog(vocab, token) {
            return (token, [], true)
        }
        let piece = tokenPiece(token)
        var mutable: [llama_token] = [token]
        let rc = mutable.withUnsafeMutableBufferPointer { buf in
            llama_decode(context, llama_batch_get_one(buf.baseAddress, 1))
        }
        guard rc == 0 else {
            throw LocallyError.inferenceFailed(
                userMessage: "The model failed while generating text.",
                technicalDetail: "llama_decode returned \(rc) during token generation")
        }
        return (token, piece, false)
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

    // MARK: - Token scoring

    /// Sum of token log-probabilities for each candidate continuation given
    /// the prompt, aligned with `candidates` order. The prompt is decoded
    /// once; each candidate's tokens are appended, scored against the cached
    /// prefix, then removed from the KV cache (llama_memory_seq_rm), so N
    /// candidates cost 1 prompt decode + N short decodes instead of N full
    /// re-decodes. Measured on SmolLM2-135M (Linux CPU): ~4x faster than
    /// re-decoding prompt+candidate per candidate (see DECISIONS.md).
    ///
    /// Scoring uses a numerically stable log-softmax over the full vocab
    /// (llama_get_logits_ith), so returned values are true log-probabilities,
    /// comparable across candidates of different token lengths.
    ///
    /// Requires an active context (beginContext); the context is left holding
    /// the decoded prompt afterwards.
    func scoreCandidates(prompt: String, candidates: [String]) throws -> [Double] {
        guard let context, let vocab else {
            throw LocallyError.runtimeUnavailable(
                userMessage: "No context is active.",
                technicalDetail: "scoreCandidates without beginContext")
        }
        let memory = llama_get_memory(context)
        let nVocab = Int(llama_vocab_n_tokens(vocab))

        let promptTokens = try tokenize(prompt, addSpecial: true)
        try decode(tokens: promptTokens)
        let promptEnd = Int32(promptTokens.count)

        var results: [Double] = []
        results.reserveCapacity(candidates.count)
        for candidate in candidates {
            // BPE tokenizers encode a word following a space differently, and
            // the rendered prompt ends right where the answer starts; score
            // the candidate with a leading space so it matches how the model
            // would continue the text.
            let continuation = candidate.hasPrefix(" ") || candidate.isEmpty
                ? candidate : " \(candidate)"
            let tokens = try tokenize(continuation, addSpecial: false)
            guard !tokens.isEmpty else {
                results.append(-.infinity)
                continue
            }
            var logProb = 0.0
            var failed = false
            for token in tokens {
                // Logits for the next token come from the last decoded
                // position (index -1 per the llama.cpp batch contract).
                guard let logits = llama_get_logits_ith(context, -1) else {
                    failed = true
                    break
                }
                logProb += Self.logSoftmax(logits: logits, count: nVocab,
                                           token: Int(token))
                var single: [llama_token] = [token]
                let rc = single.withUnsafeMutableBufferPointer { buf in
                    llama_decode(context, llama_batch_get_one(buf.baseAddress, 1))
                }
                if rc != 0 { failed = true; break }
            }
            // Roll the KV cache back to the prompt for the next candidate.
            _ = llama_memory_seq_rm(memory, 0, promptEnd, -1)
            if failed {
                throw LocallyError.inferenceFailed(
                    userMessage: "Scoring failed while reading the model's output.",
                    technicalDetail: "llama scoring decode failed mid-candidate")
            }
            results.append(logProb)
        }
        return results
    }

    /// log softmax over the vocab for one token, computed with the max-shift
    /// trick so no intermediate can overflow to +inf.
    static func logSoftmax(logits: UnsafePointer<Float>, count: Int, token: Int) -> Double {
        guard token >= 0, token < count else { return -.infinity }
        var maxLogit = -Float.infinity
        for i in 0..<count {
            let value = logits[i]
            if value > maxLogit { maxLogit = value }
        }
        guard maxLogit.isFinite else { return -.infinity }
        var sum = 0.0
        for i in 0..<count {
            sum += exp(Double(logits[i] - maxLogit))
        }
        return Double(logits[token] - maxLogit) - log(sum)
    }

    /// Approximate process resident memory in bytes. llama.cpp does not
    /// expose a per-model memory counter through the C API, so this samples
    /// process-level RSS (Linux /proc/self/statm) or physical footprint
    /// (Apple task_info). Approximate: it covers the whole process, not just
    /// this model.
    func residentMemoryBytes() -> Int64? {
        #if os(Linux)
        guard let text = try? String(contentsOfFile: "/proc/self/statm", encoding: .ascii) else {
            return nil
        }
        let fields = text.split(separator: " ")
        guard fields.count >= 2, let residentPages = Int64(fields[1]) else { return nil }
        return residentPages &* Int64(sysconf(Int32(_SC_PAGESIZE)))
        #elseif canImport(Darwin)
        var info = mach_vm_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_vm_basic_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_VM_BASIC_INFO), intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Int64(info.resident_size)
        #else
        return nil
        #endif
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
