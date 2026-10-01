import Foundation
import LocallyCore

/// Parameter-count and weight-memory estimation.
extension RepositoryAnalyzer {

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
                  requiresRemoteCode: Bool,
                  hasRunnableDiffusionVariant: Bool = false) -> [RuntimeKind] {
        guard !requiresRemoteCode else { return [] }
        switch modality {
        case .decision: return [.decision]
        // Only Core ML diffusion variants actually run; safetensors-only
        // diffusion repos are declared unsupported (see metadata).
        case .imageGeneration: return hasRunnableDiffusionVariant ? [.diffusion] : []
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
