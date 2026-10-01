import Foundation

/// Pure-Swift parser for the GGUF container header (spec version 2 and 3).
/// Reads from `Data` or a `FileHandle` slice with full bounds checks and
/// caps on counts and string/array lengths so a hostile file cannot OOM or
/// crash the process. Never mmaps untrusted data unchecked.
public struct GGUFParser: Sendable {

    /// Hard caps. A real model has tens of thousands of KV entries and
    /// hundreds of tensors at most; these are far above any legitimate file.
    public enum Limits {
        public static let maxTensorCount: UInt64 = 1_000_000
        public static let maxKVCount: UInt64 = 1_000_000
        public static let maxStringLength = 16 * 1024 * 1024
        public static let maxArrayLength: UInt64 = 10_000_000
        /// Total byte budget for the header section (metadata + tensor infos).
        public static let maxHeaderBytes = 256 * 1024 * 1024
    }

    /// GGUF metadata value types (v2/v3 tag values).
    public enum Value: Sendable, Hashable {
        case uint8(UInt8)
        case int8(Int8)
        case uint16(UInt16)
        case int16(Int16)
        case uint32(UInt32)
        case int32(Int32)
        case float32(Float)
        case bool(Bool)
        case string(String)
        case uint64(UInt64)
        case int64(Int64)
        case float64(Double)
        indirect case array([Value])
    }

    public struct TensorInfo: Sendable, Hashable {
        public var name: String
        /// Dimensions in GGUF order (innermost first). Count = number of dims.
        public var dimensions: [UInt64]
        public var ggmlType: UInt32
        public var offset: UInt64

        public var elementCount: Int64 {
            var count: Int64 = 1
            for d in dimensions {
                let (product, overflow) = count.multipliedReportingOverflow(by: Int64(clamping: d))
                if overflow { return Int64.max }
                count = product
            }
            return count
        }

        /// GGML type name, e.g. "Q4_K", "F32".
        public var typeName: String {
            Self.typeNames.indices.contains(Int(ggmlType)) ? Self.typeNames[Int(ggmlType)] : "unknown(\(ggmlType))"
        }

        // Index = enum ggml_type in ggml.h (stable wire values).
        static let typeNames = [
            "F32", "F16", "Q4_0", "Q4_1", "Q4_2", "Q4_3", "Q5_0", "Q5_1",
            "Q8_0", "Q8_1", "Q2_K", "Q3_K", "Q4_K", "Q5_K", "Q6_K", "Q8_K",
            "IQ2_XXS", "IQ2_XS", "Q3_K_XS", "IQ3_XXS", "IQ1_S", "IQ4_NL",
            "IQ3_S", "IQ2_S", "IQ4_XS", "I8", "I16", "I32", "I64", "F64",
            "IQ1_M", "BF16", "Q4_0_4_4", "Q4_0_4_8", "Q4_0_8_8",
            "TQ1_0", "TQ2_0", "MXFP4",
        ]
    }

    public struct Header: Sendable, Hashable {
        public var version: UInt32
        public var tensorCount: UInt64
        public var metadata: [String: Value]
        public var tensors: [TensorInfo]
        /// Alignment for tensor data offsets (default 32).
        public var alignment: UInt32

        public func value(_ key: String) -> Value? { metadata[key] }

        public func string(_ key: String) -> String? {
            if case .string(let s) = metadata[key] { return s }
            return nil
        }

        public func int(_ key: String) -> Int64? {
            switch metadata[key] {
            case .uint8(let v): return Int64(v)
            case .int8(let v): return Int64(v)
            case .uint16(let v): return Int64(v)
            case .int16(let v): return Int64(v)
            case .uint32(let v): return Int64(v)
            case .int32(let v): return Int64(v)
            case .uint64(let v): return Int64(clamping: v)
            case .int64(let v): return v
            default: return nil
            }
        }

        /// Total parameter count from tensor shapes (raw stored elements).
        public var parameterCount: Int64 {
            var total: Int64 = 0
            for tensor in tensors {
                let elements = tensor.elementCount
                let (sum, overflow) = total.addingReportingOverflow(elements)
                if overflow { return Int64.max }
                total = sum
            }
            return total
        }
    }

    public enum ParseError: Error, Sendable, Hashable {
        case truncated
        case badMagic
        case unsupportedVersion(UInt32)
        case limitExceeded(String)
        case invalidValue(String)
    }

    public init() {}

    public func parse(_ data: Data) throws -> Header {
        var reader = Reader(data: data)
        return try parseHeader(&reader)
    }

    /// Read and parse the header from a file. Reads at most `maxHeaderBytes`
    /// via `FileHandle` — never mmaps.
    public func parse(fileAt url: URL) throws -> Header {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: Limits.maxHeaderBytes) else {
            throw ParseError.truncated
        }
        return try parse(data)
    }

    private func parseHeader(_ r: inout Reader) throws -> Header {
        guard try r.uint32() == 0x4655_4747 else { throw ParseError.badMagic }
        let version = try r.uint32()
        guard version == 2 || version == 3 else { throw ParseError.unsupportedVersion(version) }
        let tensorCount = try r.uint64()
        let kvCount = try r.uint64()
        guard tensorCount <= Limits.maxTensorCount else {
            throw ParseError.limitExceeded("tensor_count=\(tensorCount)")
        }
        guard kvCount <= Limits.maxKVCount else {
            throw ParseError.limitExceeded("metadata_kv_count=\(kvCount)")
        }

        var metadata: [String: Value] = [:]
        metadata.reserveCapacity(Int(min(kvCount, 65_536)))
        for _ in 0..<kvCount {
            let key = try r.string()
            metadata[key] = try value(&r)
        }

        var tensors: [TensorInfo] = []
        tensors.reserveCapacity(Int(min(tensorCount, 65_536)))
        for _ in 0..<tensorCount {
            let name = try r.string()
            let nDims = try r.uint32()
            guard nDims >= 1 && nDims <= 4 else {
                throw ParseError.invalidValue("tensor \(name) has \(nDims) dims")
            }
            var dims: [UInt64] = []
            dims.reserveCapacity(Int(nDims))
            for _ in 0..<nDims { dims.append(try r.uint64()) }
            let type = try r.uint32()
            let offset = try r.uint64()
            tensors.append(TensorInfo(name: name, dimensions: dims, ggmlType: type, offset: offset))
        }

        var alignment: UInt32 = 32
        if let raw = metadata["general.alignment"] {
            switch raw {
            case .uint32(let v): alignment = v
            case .int32(let v) where v > 0: alignment = UInt32(v)
            default: throw ParseError.invalidValue("general.alignment wrong type")
            }
        }
        return Header(version: version, tensorCount: tensorCount,
                      metadata: metadata, tensors: tensors, alignment: alignment)
    }

    private func value(_ r: inout Reader) throws -> Value {
        let tag = try r.uint32()
        switch tag {
        case 0: return .uint8(try r.uint8())
        case 1: return .int8(Int8(bitPattern: try r.uint8()))
        case 2: return .uint16(try r.uint16())
        case 3: return .int16(Int16(bitPattern: try r.uint16()))
        case 4: return .uint32(try r.uint32())
        case 5: return .int32(Int32(bitPattern: try r.uint32()))
        case 6: return .float32(Float(bitPattern: try r.uint32()))
        case 7:
            let b = try r.uint8()
            guard b <= 1 else { throw ParseError.invalidValue("bool=\(b)") }
            return .bool(b == 1)
        case 8: return .string(try r.string())
        case 9:
            let elementTag = try r.uint32()
            guard elementTag != 9 else {
                throw ParseError.invalidValue("nested arrays are not valid GGUF")
            }
            let count = try r.uint64()
            guard count <= Limits.maxArrayLength else {
                throw ParseError.limitExceeded("array length=\(count)")
            }
            // Cheap up-front bounds check for fixed-size element types so a
            // huge claimed count fails before allocating element storage.
            if let fixed = Self.fixedElementSize(tag: elementTag) {
                let needed = count * UInt64(fixed)
                guard needed <= UInt64(r.remaining) else { throw ParseError.truncated }
            }
            var elements: [Value] = []
            elements.reserveCapacity(Int(min(count, 1_000_000)))
            for _ in 0..<count { elements.append(try scalarValue(tag: elementTag, &r)) }
            return .array(elements)
        case 10: return .uint64(try r.uint64())
        case 11: return .int64(Int64(bitPattern: try r.uint64()))
        case 12: return .float64(Double(bitPattern: try r.uint64()))
        default: throw ParseError.invalidValue("unknown value type tag \(tag)")
        }
    }

    private func scalarValue(tag: UInt32, _ r: inout Reader) throws -> Value {
        switch tag {
        case 0: return .uint8(try r.uint8())
        case 1: return .int8(Int8(bitPattern: try r.uint8()))
        case 2: return .uint16(try r.uint16())
        case 3: return .int16(Int16(bitPattern: try r.uint16()))
        case 4: return .uint32(try r.uint32())
        case 5: return .int32(Int32(bitPattern: try r.uint32()))
        case 6: return .float32(Float(bitPattern: try r.uint32()))
        case 7:
            let b = try r.uint8()
            guard b <= 1 else { throw ParseError.invalidValue("bool=\(b)") }
            return .bool(b == 1)
        case 8: return .string(try r.string())
        case 10: return .uint64(try r.uint64())
        case 11: return .int64(Int64(bitPattern: try r.uint64()))
        case 12: return .float64(Double(bitPattern: try r.uint64()))
        default: throw ParseError.invalidValue("bad array element tag \(tag)")
        }
    }

    private static func fixedElementSize(tag: UInt32) -> Int? {
        switch tag {
        case 0, 1, 7: return 1
        case 2, 3: return 2
        case 4, 5, 6: return 4
        case 10, 11, 12: return 8
        default: return nil // strings are length-prefixed
        }
    }
}

extension GGUFParser {
    /// Cursor over a byte buffer. All reads are bounds-checked; every failure
    /// is a thrown error, never a trap.
    struct Reader {
        let data: Data
        var offset: Int = 0

        var remaining: Int { data.count - offset }

        mutating func bytes(_ count: Int) throws -> Data.SubSequence {
            guard count >= 0, remaining >= count else { throw ParseError.truncated }
            let slice = data[offset..<(offset + count)]
            offset += count
            return slice
        }

        mutating func uint8() throws -> UInt8 {
            guard remaining >= 1 else { throw ParseError.truncated }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func uint16() throws -> UInt16 {
            let b = try bytes(2)
            return UInt16(b[b.startIndex]) | UInt16(b[b.index(b.startIndex, offsetBy: 1)]) << 8
        }

        mutating func uint32() throws -> UInt32 {
            let b = try bytes(4)
            var value: UInt32 = 0
            for i in 0..<4 { value |= UInt32(b[b.index(b.startIndex, offsetBy: i)]) << (8 * i) }
            return value
        }

        mutating func uint64() throws -> UInt64 {
            let b = try bytes(8)
            var value: UInt64 = 0
            for i in 0..<8 { value |= UInt64(b[b.index(b.startIndex, offsetBy: i)]) << (8 * i) }
            return value
        }

        mutating func string() throws -> String {
            let length = try uint64()
            guard length <= GGUFParser.Limits.maxStringLength else {
                throw ParseError.limitExceeded("string length=\(length)")
            }
            guard length <= UInt64(remaining) else { throw ParseError.truncated }
            let slice = try bytes(Int(length))
            guard let string = String(data: Data(slice), encoding: .utf8) else {
                throw ParseError.invalidValue("invalid UTF-8 string")
            }
            return string
        }
    }
}
