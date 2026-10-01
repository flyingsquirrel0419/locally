import Foundation
import LocallyCore

/// Builds a ModelDescriptor from a repository's file listing plus its small
/// config files. Pure analysis — repository code is never executed, and
/// configs that request it are flagged via `requiresRemoteCode` metadata.
public struct RepositoryAnalyzer: Sendable {

    /// Small config files fetched (capped) when present in the repo listing.
    private static let configCandidates = [
        "config.json", "model_index.json", "preprocessor_config.json",
        "tokenizer_config.json", "generation_config.json",
    ]

    public init() {}

    /// Full analysis: fetches repo metadata and configs through the client.
    public func analyze(_ reference: HFRepoReference, client: HFClient) async throws -> ModelDescriptor {
        let info = try await client.repoInfo(reference.repoID, revision: reference.revision)
        let revision = reference.revision ?? info.sha ?? "main"
        let siblings = info.siblings ?? []
        let fileNames = Set(siblings.map(\.rfilename))

        var configs: [String: ModelConfig] = [:]
        var readmeFrontMatter: CardFrontMatter?
        for name in Self.configCandidates {
            guard fileNames.contains(name) else { continue }
            if let data = try? await client.fetchSmallFile(reference.repoID, revision: revision, path: name),
               let config = try? ModelConfig(data: data) {
                configs[name] = config
            }
        }
        if fileNames.contains("README.md"),
           let data = try? await client.fetchSmallFile(reference.repoID, revision: revision, path: "README.md"),
           let text = String(data: data, encoding: .utf8) {
            readmeFrontMatter = CardFrontMatter(markdown: text)
        }

        // Safetensors headers give ground-truth parameter counts; sum across
        // all weight shards (index/metadata shards excluded). MLX repos pack
        // quantized weights as U32, so pass the declared bit width to expand
        // shapes back to logical parameter counts.
        var safetensorsHeader: ModelHeaderParser.SafetensorsHeader?
        let packedBits = configs["config.json"]?.declaredQuantization?.bits
        let weightShards = Self.primarySafetensors(siblings: siblings)
        if !weightShards.isEmpty {
            var totalParams: Int64 = 0
            var dtypes: [String: Int64] = [:]
            var parsedAny = false
            for shard in weightShards {
                guard let prefix = try? await client.fetchRange(
                    reference.repoID, revision: revision, path: shard.rfilename,
                    length: ModelHeaderParser.SafetensorsHeader.maxHeaderBytes
                ), let header = try? ModelHeaderParser.parseSafetensors(prefix, packedBits: packedBits) else { continue }
                totalParams += header.parameterCount
                for (dtype, count) in header.dtypes {
                    dtypes[dtype, default: 0] += count
                }
                parsedAny = true
            }
            if parsedAny {
                safetensorsHeader = .init(parameterCount: totalParams, dtypes: dtypes)
            }
        }

        // GGUF repos carry no config.json; the GGUF header itself is the
        // ground truth for architecture, parameter count, context length,
        // and the chat template. Range-fetch the chosen variant's header
        // (8 MB cap; one growth to 32 MB for very chat-template-heavy files).
        let ggufVariant = pickGGUFVariant(siblings: siblings)
        var ggufHeader: GGUFParser.Header?
        if let variant = ggufVariant {
            ggufHeader = await Self.fetchGGUFHeader(
                repoID: reference.repoID, revision: revision,
                path: variant.rfilename, client: client)
        }

        return buildDescriptor(
            reference: reference, revision: revision, info: info,
            siblings: siblings, configs: configs,
            frontMatter: readmeFrontMatter, safetensorsHeader: safetensorsHeader,
            ggufHeader: ggufHeader, ggufVariant: ggufVariant
        )
    }

    /// Offline analysis from an already-fetched repo listing (used by tests
    /// and by the live-check script's fixture path).
    public func analyze(info: HFRepoInfo, configs: [String: ModelConfig],
                        frontMatter: CardFrontMatter?,
                        safetensorsHeader: ModelHeaderParser.SafetensorsHeader?,
                        reference: HFRepoReference) -> ModelDescriptor {
        buildDescriptor(
            reference: reference, revision: reference.revision ?? info.sha ?? "main",
            info: info, siblings: info.siblings ?? [], configs: configs,
            frontMatter: frontMatter, safetensorsHeader: safetensorsHeader,
            ggufHeader: nil, ggufVariant: nil
        )
    }

    // MARK: - Descriptor assembly

    private func buildDescriptor(
        reference: HFRepoReference, revision: String, info: HFRepoInfo,
        siblings: [HFSibling], configs: [String: ModelConfig],
        frontMatter: CardFrontMatter?, safetensorsHeader: ModelHeaderParser.SafetensorsHeader?,
        ggufHeader: GGUFParser.Header?, ggufVariant: HFSibling?
    ) -> ModelDescriptor {
        let config = configs["config.json"]
        let tags = Set((info.tags ?? []) + (frontMatter?.tags ?? []))
        let pipelineTag = info.pipelineTag ?? frontMatter?.pipelineTag
        let libraryName = info.libraryName ?? frontMatter?.libraryName

        let modality = detectModality(pipelineTag: pipelineTag, config: config,
                                      modelIndex: configs["model_index.json"],
                                      tags: tags, architectures: architectures(from: config))
        let ggufVariant = ggufVariant ?? pickGGUFVariant(siblings: siblings)
        let ggufSummary = ggufHeader.map { GGUFModelSummary(header: $0) }
        let formats = detectFormats(siblings: siblings, libraryName: libraryName,
                                    config: config, tags: tags, repoOwner: reference.repoID.owner)
        let quantization = detectQuantization(config: config, tags: tags,
                                              ggufVariant: ggufVariant,
                                              repoName: reference.repoID.name)
        let parameters = safetensorsHeader?.parameterCount
            ?? (ggufSummary.map { $0.parameterCount }?.nilIfZero)
            ?? estimateParametersFromConfig(config)
            ?? estimateParametersFromName(reference.repoID.name)
        let context = config?.maxPositionEmbeddings
            ?? configs["generation_config.json"]?.maxPositionEmbeddings
            ?? ggufSummary?.contextLength
        let hints = architectureHints(from: config)
            ?? ggufHeader.map { ArchitectureHints(ggufMetadata: Self.ggufMetadataDictionary($0)) }

        let required = selectRequiredFiles(siblings: siblings, ggufVariant: ggufVariant,
                                           formats: formats)
        let totalSize = required.reduce(Int64(0)) { $0 + $1.size }
        let weightMemory = estimateWeightMemory(parameters: parameters, quantization: quantization,
                                                requiredSize: required.isEmpty ? nil : totalSize)

        var metadata: [String: String] = [:]
        if let pipelineTag { metadata["pipeline_tag"] = pipelineTag }
        if let libraryName { metadata["library_name"] = libraryName }
        if let license = frontMatter?.license { metadata["license"] = license }
        if let modelType = config?.modelType { metadata["model_type"] = modelType }
        metadata["revision"] = revision
        if info.gated != nil { metadata["gated"] = "true" }
        if config?.requiresRemoteCode == true { metadata["requiresRemoteCode"] = "true" }
        if let header = safetensorsHeader {
            metadata["safetensors_dtypes"] = header.dtypes
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
        }
        if let summary = ggufSummary {
            // Ground truth from the GGUF header itself: quantization scheme
            // from file_type, chat-template presence for the prompt builder.
            if let scheme = summary.quantization?.scheme, metadata["quantization"] == nil {
                metadata["quantization"] = scheme
            }
            if summary.chatTemplate != nil { metadata["chat_template"] = "gguf" }
            if let arch = summary.architecture { metadata["gguf_architecture"] = arch }
        }

        return ModelDescriptor(
            repoID: reference.repoID.description,
            name: reference.repoID.name,
            architecture: config?.architecture,
            modality: modality,
            parameterCount: parameters,
            quantization: quantization,
            formats: formats,
            totalDownloadSize: required.isEmpty ? nil : totalSize,
            requiredFiles: required,
            estimatedWeightMemory: weightMemory,
            estimatedRuntimeMemory: nil,
            supportedRuntimes: runtimes(for: formats, modality: modality,
                                        requiresRemoteCode: config?.requiresRemoteCode == true),
            contextLength: context,
            architectureHints: hints,
            metadata: metadata
        )
    }

    // MARK: - GGUF header fetch

    /// Range-fetch the GGUF header for `path` and parse it. The header is
    /// metadata + tensor infos only, so 8 MB covers essentially every real
    /// model; if a parse comes back truncated (an enormous chat template or
    /// tokenizer list can push past 8 MB) one retry at 32 MB is allowed.
    /// Returns nil when the file doesn't parse — analysis then falls back
    /// to name/config heuristics exactly as before.
    static func fetchGGUFHeader(repoID: RepoID, revision: String, path: String,
                                client: HFClient) async -> GGUFParser.Header? {
        let initial: Int64 = 8 * 1024 * 1024
        let grown: Int64 = 32 * 1024 * 1024
        for cap in [initial, grown] {
            guard let data = try? await client.fetchRange(
                repoID, revision: revision, path: path, length: cap
            ) else { return nil }
            do {
                return try GGUFParser().parse(data)
            } catch GGUFParser.ParseError.truncated where cap == initial {
                continue  // grow once and retry
            } catch {
                return nil
            }
        }
        return nil
    }

    /// Flatten a parsed GGUF header into the `[String: Any]` shape
    /// `ArchitectureHints(ggufMetadata:)` expects: arch-prefixed numeric
    /// keys plus the tokenizer list used for the vocab-size fallback.
    static func ggufMetadataDictionary(_ header: GGUFParser.Header) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in header.metadata {
            switch value {
            case .uint8(let v): out[key] = Int(v)
            case .int8(let v): out[key] = Int(v)
            case .uint16(let v): out[key] = Int(v)
            case .int16(let v): out[key] = Int(v)
            case .uint32(let v): out[key] = Int(v)
            case .int32(let v): out[key] = Int(v)
            case .uint64(let v): out[key] = Int(clamping: v)
            case .int64(let v): out[key] = Int(clamping: v)
            case .float32(let v): out[key] = Double(v)
            case .float64(let v): out[key] = v
            case .bool(let v): out[key] = v
            case .string(let v): out[key] = v
            case .array(let elements):
                // Only the tokenizer token list is consumed (for its count),
                // and only as strings; other arrays are ignored.
                if key == "tokenizer.ggml.tokens" {
                    out[key] = elements.compactMap { value -> String? in
                        if case .string(let s) = value { return s }
                        return nil
                    }
                }
            }
        }
        return out
    }

    // MARK: - Modality

    func detectModality(pipelineTag: String?, config: ModelConfig?,
                        modelIndex: ModelConfig?, tags: Set<String>,
                        architectures: [String]) -> ModelModality {
        let arch = architectures.joined(separator: " ").lowercased()
        let tagSet = Set(tags.map { $0.lowercased() })
        let pipeline = pipelineTag?.lowercased()

        if tagSet.contains("sentence-transformers") || pipeline == "sentence-similarity"
            || pipeline == "feature-extraction" && arch.contains("bert") {
            return .embedding
        }
        if tagSet.contains("cross-encoder") || tagSet.contains("reranker")
            || pipeline == "text-ranking" {
            return .reranker
        }
        if let pipeline {
            switch pipeline {
            case "text-generation", "text2text-generation":
                if config?.hasVisionConfig == true { return .visionLanguage }
                return .text
            case "image-text-to-text", "visual-question-answering":
                return .visionLanguage
            case "automatic-speech-recognition":
                return .speechRecognition
            case "text-to-speech":
                return .speechSynthesis
            case "text-to-image", "image-to-image", "inpainting":
                return .imageGeneration
            case "text-to-video":
                return .videoGeneration
            case "image-classification", "object-detection", "image-segmentation":
                return .imageUnderstanding
            case "fill-mask", "token-classification", "question-answering",
                 "summarization", "translation", "zero-shot-classification":
                return .text
            default: break
            }
        }
        // Diffusion repos ship a model_index.json pointing at UNet/Transformer modules.
        if let modelIndex {
            let keys = modelIndex.raw.keys.joined(separator: " ").lowercased()
            if keys.contains("unet") || keys.contains("transformer") || keys.contains("vae") {
                return .imageGeneration
            }
        }
        if arch.contains("forcausallm") {
            return config?.hasVisionConfig == true ? .visionLanguage : .text
        }
        if arch.contains("forconditionalgeneration") {
            return config?.hasVisionConfig == true ? .visionLanguage : .text
        }
        if arch.contains("whisper") { return .speechRecognition }
        if arch.contains("vl") || config?.hasVisionConfig == true { return .visionLanguage }
        if tagSet.contains("video") { return .videoUnderstanding }
        return .unknown
    }

    private func architectures(from config: ModelConfig?) -> [String] {
        config?["architectures"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    // MARK: - Formats & quantization

    func detectFormats(siblings: [HFSibling], libraryName: String?, config: ModelConfig?,
                       tags: Set<String>, repoOwner: String) -> [ModelFormat] {
        var formats: [ModelFormat] = []
        let names = siblings.map { $0.rfilename.lowercased() }
        let tagSet = Set(tags.map { $0.lowercased() })
        let hasSafetensors = names.contains { $0.hasSuffix(".safetensors") }

        if libraryName?.lowercased() == "mlx" || repoOwner == "mlx-community"
            || (tagSet.contains("mlx") && hasSafetensors) {
            formats.append(.mlx)
        }
        if names.contains(where: { $0.hasSuffix(".gguf") }) { formats.append(.gguf) }
        if names.contains(where: { $0.hasSuffix(".mlpackage") || $0.hasSuffix(".mlmodelc") }) {
            formats.append(.coreml)
        }
        if names.contains(where: { $0.hasSuffix(".onnx") }) { formats.append(.onnx) }
        if hasSafetensors && !formats.contains(.mlx) { formats.append(.safetensors) }
        if formats.isEmpty && names.contains(where: { $0.hasSuffix(".bin") }) {
            formats.append(.other)
        }
        return formats
    }

    func detectQuantization(config: ModelConfig?, tags: Set<String>,
                            ggufVariant: HFSibling?, repoName: String) -> Quantization? {
        if let declared = config?.declaredQuantization {
            return Quantization(bits: declared.bits, scheme: declared.scheme)
        }
        if let variant = ggufVariant {
            let fileName = variant.rfilename
            if let match = fileName.firstRange(of: #/(?i)(Q\d(?:_K)?(?:_[SML])?|IQ\d_XXS|F16|F32|BF16)/#) {
                return Quantization.parse(String(fileName[match]))
            }
        }
        if let match = repoName.firstRange(of: #/(?i)(\d{1,2})[- ]?bit/#) {
            return Quantization.parse(String(repoName[match]))
        }
        let tagSet = tags.map { $0.lowercased() }
        for tag in tagSet {
            if let parsed = Quantization.parse(tag) { return parsed }
        }
        return nil
    }

    // MARK: - Architecture hints

    /// Reads transformer structure from config.json, looking into
    /// `text_config`/`vision_config` for VLMs. Returns nil when the config
    /// exposes nothing usable.
    func architectureHints(from config: ModelConfig?) -> ArchitectureHints? {
        guard let config else { return nil }
        let root = config.raw
        let text = root["text_config"]?.objectValue ?? root
        let vision = root["vision_config"]?.objectValue

        let hidden = text["hidden_size"]?.intValue
        let layers = text["num_hidden_layers"]?.intValue
        let heads = text["num_attention_heads"]?.intValue
        let kvHeads = text["num_key_value_heads"]?.intValue
        let headDim = text["head_dim"]?.intValue
        let vocab = text["vocab_size"]?.intValue
        let intermediate = text["intermediate_size"]?.intValue
        let sliding = text["sliding_window"]?.intValue
            ?? text["sliding_window_size"]?.intValue

        // Vision encoder parameter estimate from its own config block:
        // embedding + per-layer (attention + MLP), LLaVA/Qwen-VL style.
        var visionParams: Int64?
        if let vision,
           let vh = vision["hidden_size"]?.intValue,
           let vl = vision["num_hidden_layers"]?.intValue ?? vision["depth"]?.intValue {
            let vHeads = vision["num_attention_heads"]?.intValue ?? max(1, vh / 64)
            let vIntermediate = vision["intermediate_size"]?.intValue ?? 4 * vh
            let h = Int64(vh), l = Int64(vl)
            let perLayer = 4 * h * h + 2 * h * Int64(vIntermediate)
            _ = vHeads // heads only affect shape split, not count
            visionParams = l * perLayer
        }

        guard hidden != nil || layers != nil || visionParams != nil else { return nil }
        return ArchitectureHints(
            numLayers: layers,
            hiddenSize: hidden,
            numAttentionHeads: heads,
            numKVHeads: kvHeads,
            headDim: headDim,
            vocabSize: vocab,
            intermediateSize: intermediate,
            slidingWindow: sliding,
            visionEncoderParams: visionParams
        )
    }

    // MARK: - Parameter estimation

    /// LLaMA/Qwen-style estimate from config fields:
    /// embedding + per-layer (attention + MLP) weights.
    func estimateParametersFromConfig(_ config: ModelConfig?) -> Int64? {
        guard let config else { return nil }
        let root = config.raw
        let text = root["text_config"]?.objectValue ?? root
        guard let hidden = text["hidden_size"]?.intValue,
              let layers = text["num_hidden_layers"]?.intValue else { return nil }
        let vocab = text["vocab_size"]?.intValue ?? 0
        let intermediate = text["intermediate_size"]?.intValue ?? 0
        let heads = text["num_attention_heads"]?.intValue ?? 0
        let kvHeads = text["num_key_value_heads"]?.intValue ?? heads
        let headDim = text["head_dim"]?.intValue
            ?? (heads > 0 ? hidden / heads : 0)

        let h = Int64(hidden), l = Int64(layers), v = Int64(vocab)
        let i = Int64(intermediate), hd = Int64(headDim)
        let kv = Int64(kvHeads)

        let qProj = h * (Int64(heads) * hd)
        let kvProj = 2 * h * (kv * hd)
        let oProj = (Int64(heads) * hd) * h
        let attention = qProj + kvProj + oProj
        let mlp = intermediate > 0 ? 3 * h * i : 4 * h * h
        let perLayer = attention + mlp

        let tied = text["tie_word_embeddings"]?.boolValue ?? false
        let embeddings = v * h
        let lmHead = tied ? 0 : embeddings

        let total = embeddings + lmHead + l * perLayer
        return total > 0 ? total : nil
    }

    func estimateParametersFromName(_ name: String) -> Int64? {
        guard let match = name.firstRange(of: #/(?i)(\d+(?:\.\d+)?)\s*([bBmM])\b/#) else {
            return nil
        }
        let token = String(name[match])
        let scalar = token.dropLast()
        guard let value = Double(scalar) else { return nil }
        let multiplier: Double = token.last == "m" || token.last == "M" ? 1_000_000 : 1_000_000_000
        return Int64(value * multiplier)
    }

    // MARK: - File selection

    /// Default GGUF variant: Q4_K_M when present, else the smallest quant
    /// at 4 bits or more.
    func pickGGUFVariant(siblings: [HFSibling]) -> HFSibling? {
        let ggufs = siblings.filter { $0.rfilename.lowercased().hasSuffix(".gguf") }
        guard !ggufs.isEmpty else { return nil }
        if let q4km = ggufs.first(where: { $0.rfilename.uppercased().contains("Q4_K_M") }) {
            return q4km
        }
        let quants: [(file: HFSibling, quant: Quantization)] = ggufs.compactMap { file in
            guard let range = file.rfilename.firstRange(of: #/(?i)(Q\d(?:_K)?(?:_[SML])?|IQ\d_XXS)/#),
                  let q = Quantization.parse(String(file.rfilename[range])) else { return nil }
            return (file, q)
        }
        let candidates = quants.filter { $0.quant.bits >= 4 }
        let pool = candidates.isEmpty ? quants : candidates
        return pool.min {
            ($0.file.size ?? .max) < ($1.file.size ?? .max)
        }?.file ?? ggufs.first
    }

    /// The files actually needed to run: the chosen variant's weights plus
    /// config/tokenizer/support files. Excludes other quantizations, .bin
    /// duplicates when safetensors exist, alternative framework formats, and
    /// docs/images.
    func selectRequiredFiles(siblings: [HFSibling], ggufVariant: HFSibling?,
                             formats: [ModelFormat]) -> [RemoteModelFile] {
        let hasGGUF = formats.contains(.gguf)
        let hasSafetensors = formats.contains(.safetensors) || formats.contains(.mlx)

        return siblings.compactMap { sibling in
            let path = sibling.rfilename
            let lower = path.lowercased()

            if lower.hasPrefix(".git") { return nil }
            if Self.isNonRuntimeFile(lower) { return nil }
            if lower.hasSuffix(".gguf") {
                guard let variant = ggufVariant, path == variant.rfilename else { return nil }
            } else if lower.hasSuffix(".bin") {
                if hasSafetensors || hasGGUF { return nil }
            } else if lower.hasSuffix(".safetensors") {
                if hasGGUF { return nil }
            } else if lower.hasSuffix(".onnx") || lower.hasSuffix(".mlpackage")
                        || lower.hasSuffix(".mlmodelc") || lower.hasSuffix(".pt")
                        || lower.hasSuffix(".pth") || lower.hasSuffix(".ckpt")
                        || lower.hasSuffix(".h5") || lower.hasSuffix(".msgpack")
                        || lower.hasSuffix(".tflite") {
                // Alternate framework formats are not required once a primary
                // format (GGUF/MLX/safetensors) is chosen.
                if hasGGUF || hasSafetensors || formats.contains(.coreml) == false { return nil }
            }

            let size = sibling.lfs?.size ?? sibling.size ?? 0
            return RemoteModelFile(path: path, size: size, sha256: sibling.lfs?.sha256)
        }
    }

    /// Top-level safetensors weight shards ("model.safetensors",
    /// "model-NNNNN-of-NNNNN.safetensors"), excluding sub-component files
    /// (diffusion unet/vae/text_encoder live in subdirectories).
    static func primarySafetensors(siblings: [HFSibling]) -> [HFSibling] {
        siblings.filter {
            $0.rfilename.lowercased().hasSuffix(".safetensors")
                && !$0.rfilename.contains("/")
        }
    }

    /// Files that never belong in a runtime download: llama.cpp importance
    /// matrices (calibration data for quantizing, not inference), docs,
    /// images, VCS attributes, licenses, and other metadata-only artifacts.
    /// `lower` is already lowercased.
    static func isNonRuntimeFile(_ lower: String) -> Bool {
        if lower.hasSuffix(".imatrix") { return true }
        if lower.hasSuffix(".md") || lower.hasSuffix(".markdown")
            || lower.hasSuffix(".pdf") { return true }
        if lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
            || lower.hasSuffix(".gif") || lower.hasSuffix(".webp") || lower.hasSuffix(".svg")
            || lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") { return true }
        let base = (lower as NSString).lastPathComponent
        if base == ".gitattributes" || base == ".gitignore" || base == "license"
            || base == "license.txt" || base == "license.md" || base == "copying"
            || base == "notice" || base == "authors" || base == "contributors" { return true }
        return false
    }

    // MARK: - Memory & runtimes

    /// Weight memory: the true download size when weights were selected,
    /// else parameters × bytes-per-parameter. Labeled an estimate by callers.
    func estimateWeightMemory(parameters: Int64?, quantization: Quantization?,
                              requiredSize: Int64?) -> Int64? {
        if let requiredSize { return requiredSize }
        guard let parameters else { return nil }
        let bytesPerParam = quantization?.bytesPerParameter ?? 2.0 // fp16 default
        return Int64(Double(parameters) * bytesPerParam)
    }

    func runtimes(for formats: [ModelFormat], modality: ModelModality,
                  requiresRemoteCode: Bool) -> [RuntimeKind] {
        guard !requiresRemoteCode else { return [] }
        switch modality {
        case .decision: return [.decision]
        case .imageGeneration: return formats.contains(.coreml) || formats.contains(.safetensors)
            ? [.diffusion] : []
        case .speechRecognition, .speechSynthesis, .audio: return [.audio]
        case .videoUnderstanding, .videoGeneration: return [.video]
        default:
            if formats.contains(.mlx) { return [.mlx] }
            if formats.contains(.gguf) { return [.gguf] }
            if formats.contains(.coreml) { return [.coreml] }
            return []
        }
    }
}

private extension Int64 {
    /// Parameter counts of zero are useless — treat as missing.
    var nilIfZero: Int64? { self == 0 ? nil : self }
}
