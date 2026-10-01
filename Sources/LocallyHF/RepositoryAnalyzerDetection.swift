import Foundation
import LocallyCore

/// Modality, format, quantization, and architecture-hint detection.
extension RepositoryAnalyzer {

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

    func architectures(from config: ModelConfig?) -> [String] {
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
        // Compiled Core ML: direct .mlmodelc trees, or the Core ML
        // diffusion convention of one "<variant>_compiled.zip" archive
        // whose contents are .mlmodelc folders.
        if names.contains(where: { $0.hasSuffix(".mlpackage") || $0.hasSuffix(".mlmodelc") })
            || (tagSet.contains("coreml")
                && names.contains { $0.hasSuffix("compiled.zip") || $0.contains(".mlmodelc/") }) {
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
}
