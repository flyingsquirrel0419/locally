import Foundation

/// Incremental CRC-32 (ISO 3309, the ZIP polynomial) over streamed chunks.
public struct CRC32: Sendable {
    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private var state: UInt32 = 0xFFFF_FFFF

    public init() {}

    public mutating func update(_ data: Data) {
        var c = state
        for byte in data {
            c = Self.table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        state = c
    }

    public var value: UInt32 { state ^ 0xFFFF_FFFF }
}
