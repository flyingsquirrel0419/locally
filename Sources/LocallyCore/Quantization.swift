import Foundation

/// Quantization description: bit width plus an optional scheme name
/// (e.g. "Q4_K_M", "int8", "fp16", "af4_0").
public struct Quantization: Codable, Sendable, Hashable {
    public var bits: Int
    public var scheme: String?

    public init(bits: Int, scheme: String? = nil) {
        self.bits = bits
        self.scheme = scheme
    }

    /// Bytes per parameter, ignoring per-block scale/metadata overhead.
    public var bytesPerParameter: Double { Double(bits) / 8.0 }

    /// Best-effort parse of a quantization string such as "Q4_K_M", "4bit",
    /// "int8", "fp16", "bf16", "8-bit", "af4_0". Returns nil when unrecognized.
    public static func parse(_ raw: String) -> Quantization? {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return nil }

        // fp16 / bf16 / float16 style
        if let match = lower.firstMatch(of: #/^(f|bf|fp|float)?\s*(\d{1,2})$/#),
           let bits = Int(match.2), bits >= 2, bits <= 64 {
            return Quantization(bits: bits, scheme: raw)
        }
        // int8 / uint4 style
        if let match = lower.firstMatch(of: #/^[ui]?int(\d{1,2})$/#),
           let bits = Int(match.1), bits >= 2, bits <= 64 {
            return Quantization(bits: bits, scheme: raw)
        }
        // Q4_K_M / Q5_0 GGUF style
        if let match = lower.firstMatch(of: #/^q(\d{1,2})(?:_(.+))?$/#),
           let bits = Int(match.1), bits >= 2, bits <= 16 {
            return Quantization(bits: bits, scheme: raw.uppercased())
        }
        // "4bit" / "8-bit" style
        if let match = lower.firstMatch(of: #/^(\d{1,2})\s*-?\s*bit$/#),
           let bits = Int(match.1), bits >= 2, bits <= 64 {
            return Quantization(bits: bits, scheme: raw)
        }
        return nil
    }
}
