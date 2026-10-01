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

        return buildDescriptor(
            reference: reference, revision: revision, info: info,
            siblings: siblings, configs: configs,
            frontMatter: readmeFrontMatter, safetensorsHeader: safetensorsHeader
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
            frontMatter: frontMatter, safetensorsHeader: safetensorsHeader
        )
    }

    // MARK: - Descriptor assembly

    private func buildDescriptor(
        reference: HFRepoReference, revision: String, info: HFRepoInfo,
        siblings: [HFSibling], configs: [String: ModelConfig],
        frontMatter: CardFrontMatter?, safetensorsHeader: ModelHeaderParser.SafetensorsHeader?
    ) -> ModelDescriptor {
        let config = configs["config.json"]
        let tags = Set((info.tags ?? []) + (frontMatter?.tags ?? []))
        let pipelineTag = info.pipelineTag ?? frontMatter?.pipelineTag
        let libraryName = info.libraryName ?? frontMatter?.libraryName

        let modality = detectModality(pipelineTag: pipelineTag, config: config,
                                      modelIndex: configs["model_index.json"],
                                      tags: tags, architectures: architectures(from: config))
        let ggufVariant = pickGGUFVariant(siblings: siblings)
        let formats = detectFormats(siblings: siblings, libraryName: libraryName,
                                    config: config, tags: tags, repoOwner: reference.repoID.owner)
        let quantization = detectQuantization(config: config, tags: tags,
                                              ggufVariant: ggufVariant,
                                              repoName: reference.repoID.name)
        let parameters = safetensorsHeader?.parameterCount
            ?? estimateParametersFromConfig(config)
            ?? estimateParametersFromName(reference.repoID.name)
        let context = config?.maxPositionEmbeddings
            ?? configs["generation_config.json"]?.maxPositionEmbeddings

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
            metadata: metadata
        )
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
            } else if lower.hasSuffix(".png") || lower.hasSuffix(".jpg")
                        || lower.hasSuffix(".jpeg") || lower.hasSuffix(".gif")
                        || lower.hasSuffix(".webp") || lower.hasSuffix(".mp4")
                        || lower == "readme.md" || lower.hasSuffix(".pdf")
                        || lower.hasSuffix(".gitattributes") {
                return nil
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
