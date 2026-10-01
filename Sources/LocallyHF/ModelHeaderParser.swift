import Foundation
import LocallyCore

/// Header readers for binary model formats. These read only the leading
/// metadata bytes of a file (via HTTP Range) — tensors are never loaded here.
public enum ModelHeaderParser {

    /// Safetensors layout: UInt64 LE header length, then a JSON header with
    /// per-tensor dtype/shape entries, then the tensor buffer.
    public struct SafetensorsHeader: Sendable {
        public var parameterCount: Int64
        public var dtypes: [String: Int64]

        /// Bytes needed to parse: 8-byte length prefix + header JSON.
        public static let maxHeaderBytes: Int64 = 8 + 1024 * 1024
    }

    public enum HeaderError: Error, Sendable {
        case truncated
        case badMagic
        case unsupportedVersion
    }

    /// Parse from the raw bytes already fetched (must include the 8-byte
    /// length prefix and the full JSON header). `packedBits` corrects MLX
    /// quantized repos, whose `weight` tensors store packed shapes
    /// ([rows, cols/(32/bits)] U32) — element counts for those are expanded
    /// back to the logical parameter count. `nil` counts elements as stored.
    public static func parseSafetensors(_ data: Data,
                                        packedBits: Int? = nil) throws -> SafetensorsHeader {
        guard data.count >= 8 else { throw HeaderError.truncated }
        let headerLength = UInt64(littleEndian: data.withUnsafeBytes { $0.load(as: UInt64.self) })
        guard headerLength <= 1024 * 1024, data.count >= 8 + Int(headerLength) else {
            throw HeaderError.truncated
        }
        let json = data.subdata(in: 8..<(8 + Int(headerLength)))
        guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw HeaderError.badMagic
        }
        var paramCount: Int64 = 0
        var dtypes: [String: Int64] = [:]
        for (key, value) in object {
            guard key != "__metadata__",
                  let entry = value as? [String: Any],
                  let dtype = entry["dtype"] as? String,
                  let shape = entry["shape"] as? [NSNumber] else { continue }
            var elements = shape.reduce(Int64(1)) { $0 * $1.int64Value }
            if let bits = packedBits, bits > 0, bits < 32,
               key.hasSuffix(".weight"), dtype == "U32" || dtype == "I32" {
                // Packed quantized weight: each U32 element holds 32/bits params.
                elements *= Int64(32 / bits)
            }
            paramCount += elements
            dtypes[dtype, default: 0] += elements
        }
        return SafetensorsHeader(parameterCount: paramCount, dtypes: dtypes)
    }

    /// GGUF fixed header: magic "GGUF", UInt32 version, UInt64 tensor count,
    /// UInt64 metadata KV count. The full metadata walk is Week 6 work.
    public struct GGUFHeader: Sendable {
        public var version: UInt32
        public var tensorCount: UInt64
        public var metadataCount: UInt64

        public static let byteCount: Int64 = 24
    }

    public static func parseGGUFHeader(_ data: Data) throws -> GGUFHeader {
        guard data.count >= Int(GGUFHeader.byteCount) else { throw HeaderError.truncated }
        return try data.withUnsafeBytes { buffer in
            let magic = buffer.load(as: UInt32.self)
            guard magic == 0x4655_4747 else { throw HeaderError.badMagic } // "GGUF" LE
            let version = buffer.load(fromByteOffset: 4, as: UInt32.self)
            guard version == 2 || version == 3 else { throw HeaderError.unsupportedVersion }
            return GGUFHeader(
                version: version,
                tensorCount: buffer.load(fromByteOffset: 8, as: UInt64.self),
                metadataCount: buffer.load(fromByteOffset: 16, as: UInt64.self)
            )
        }
    }
}
