import Foundation

/// Structured, typed view over a parsed GGUF header's metadata.
public struct GGUFModelSummary: Sendable, Hashable {
    public var architecture: String?
    public var name: String?
    public var contextLength: Int?
    public var blockCount: Int?
    public var embeddingLength: Int?
    public var headCount: Int?
    public var headCountKV: Int?
    public var fileType: UInt32?
    public var quantization: Quantization?
    public var chatTemplate: String?
    public var parameterCount: Int64
    public var alignment: UInt32

    public init(header: GGUFParser.Header) {
        let arch = header.string("general.architecture")
        architecture = arch
        name = header.string("general.name")
        alignment = header.alignment
        parameterCount = header.parameterCount

        if let arch = arch {
            contextLength = header.int("\(arch).context_length").map { Int(clamping: $0) }
            blockCount = header.int("\(arch).block_count").map { Int(clamping: $0) }
            embeddingLength = header.int("\(arch).embedding_length").map { Int(clamping: $0) }
            headCount = header.int("\(arch).attention.head_count").map { Int(clamping: $0) }
            headCountKV = header.int("\(arch).attention.head_count_kv").map { Int(clamping: $0) }
        }
        chatTemplate = header.string("tokenizer.chat_template")

        if let fileType = header.int("general.file_type"), fileType >= 0 {
            self.fileType = UInt32(clamping: fileType)
            quantization = Self.quantization(fileType: UInt32(clamping: fileType))
        }
    }

    /// GGUF `general.file_type` enum → Quantization. Values mirror the
    /// `llama_ftype` enum of the pinned llama.cpp release (v0.5.0);
    /// unknown/newer values return nil.
    public static func quantization(fileType: UInt32) -> Quantization? {
        let scheme: String
        switch fileType {
        case 0: scheme = "F32"
        case 1: scheme = "F16"
        case 2: scheme = "Q4_0"
        case 3: scheme = "Q4_1"
        case 7: scheme = "Q8_0"
        case 8: scheme = "Q5_0"
        case 9: scheme = "Q5_1"
        case 10: scheme = "Q2_K"
        case 11: scheme = "Q3_K_S"
        case 12: scheme = "Q3_K_M"
        case 13: scheme = "Q3_K_L"
        case 14: scheme = "Q4_K_S"
        case 15: scheme = "Q4_K_M"
        case 16: scheme = "Q5_K_S"
        case 17: scheme = "Q5_K_M"
        case 18: scheme = "Q6_K"
        case 19: scheme = "IQ2_XXS"
        case 20: scheme = "IQ2_XS"
        case 21: scheme = "Q2_K_S"
        case 22: scheme = "IQ3_XS"
        case 23: scheme = "IQ3_XXS"
        case 24: scheme = "IQ1_S"
        case 25: scheme = "IQ4_NL"
        case 26: scheme = "IQ3_S"
        case 27: scheme = "IQ3_M"
        case 28: scheme = "IQ2_S"
        case 29: scheme = "IQ2_M"
        case 30: scheme = "IQ4_XS"
        case 31: scheme = "IQ1_M"
        case 32: scheme = "BF16"
        case 36: scheme = "TQ1_0"
        case 37: scheme = "TQ2_0"
        case 38: scheme = "MXFP4_MOE"
        case 39: scheme = "NVFP4"
        default: return nil
        }
        return Quantization.parse(scheme) ?? Quantization(bits: 0, scheme: scheme)
    }
}
