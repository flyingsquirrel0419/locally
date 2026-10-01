import Foundation
import LocallyCore

/// GGUF-specific analysis: header range-fetch and metadata flattening.
extension RepositoryAnalyzer {

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
}
