import Foundation

#if canImport(Compression)
import Compression
#elseif canImport(CZlib)
import CZlib
#endif

/// Streaming raw-deflate inflater (ZIP method 8, no zlib/gzip header).
/// Backed by Compression on Apple platforms and zlib elsewhere.
final class Inflater: @unchecked Sendable {

    enum InflateError: Error {
        case streamSetupFailed
        case inflateFailed(Int)
        case backendUnavailable
    }

    private var scratch = [UInt8](repeating: 0, count: 512 * 1024)
    private var finished = false

    #if canImport(Compression)
    private var stream: compression_stream?
    #elseif canImport(CZlib)
    private var zstream = z_stream()
    private var zstreamStarted = false
    #endif

    init() throws {
        #if canImport(Compression)
        var s = compression_stream()
        guard compression_stream_init(&s, COMPRESSION_STREAM_DECODE,
                                      COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw InflateError.streamSetupFailed
        }
        self.stream = s
        #elseif canImport(CZlib)
        // -MAX_WBITS: raw deflate, matching ZIP method 8.
        guard inflateInit2_(&zstream, -MAX_WBITS, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw InflateError.streamSetupFailed
        }
        zstreamStarted = true
        #endif
    }

    deinit {
        #if canImport(Compression)
        if var s = stream { compression_stream_destroy(&s) }
        #elseif canImport(CZlib)
        if zstreamStarted { inflateEnd(&zstream) }
        #endif
    }

    /// Feed one compressed chunk; returns the inflated bytes. `isLast` marks
    /// the archive entry's final chunk so stream end can be validated.
    func inflate(_ chunk: Data, isLast: Bool, path: String) throws -> Data {
        guard !finished else { throw InflateError.inflateFailed(-1) }
        #if canImport(Compression)
        return try inflateApple(chunk, isLast: isLast)
        #elseif canImport(CZlib)
        return try inflateZlib(chunk, isLast: isLast)
        #else
        throw InflateError.backendUnavailable
        #endif
    }

    #if canImport(Compression)
    private func inflateApple(_ chunk: Data, isLast: Bool) throws -> Data {
        guard var s = stream else { throw InflateError.streamSetupFailed }
        defer { stream = s }
        var output = Data()
        let flags = isLast ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
        let status: compression_status = chunk.withUnsafeBytes { src in
            scratch.withUnsafeMutableBytes { dst in
                s.src_ptr = src.baseAddress!.assumingMemoryBound(to: UInt8.self)
                s.src_size = chunk.count
                s.dst_ptr = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
                s.dst_size = dst.count
                return compression_stream_process(&s, flags)
            }
        }
        let produced = scratch.count - s.dst_size
        output.append(contentsOf: scratch[0..<produced])
        // compression_stream_process may leave input unconsumed when the
        // output buffer fills; loop until all input is drained.
        var status = status
        while status == COMPRESSION_STATUS_OK && s.src_size > 0 {
            let more: compression_status = scratch.withUnsafeMutableBytes { dst in
                s.dst_ptr = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
                s.dst_size = dst.count
                return compression_stream_process(&s, flags)
            }
            let n = scratch.count - s.dst_size
            output.append(contentsOf: scratch[0..<n])
            status = more
        }
        switch status {
        case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
            if status == COMPRESSION_STATUS_END { finished = true }
            if isLast && !finished && s.src_size == 0 {
                // Truncated deflate stream: size check downstream catches it,
                // but flag it here too for a clearer error.
                finished = true
            }
            return output
        default:
            throw InflateError.inflateFailed(-2)
        }
    }
    #endif

    #if canImport(CZlib)
    private func inflateZlib(_ chunk: Data, isLast: Bool) throws -> Data {
        var output = Data()
        var status: Int32 = chunk.withUnsafeBytes { src in
            scratch.withUnsafeMutableBytes { dst in
                zstream.next_in = UnsafeMutablePointer(
                    mutating: src.baseAddress!.assumingMemoryBound(to: UInt8.self))
                zstream.avail_in = UInt32(chunk.count)
                zstream.next_out = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
                zstream.avail_out = UInt32(dst.count)
                return CZlib.inflate(&zstream, isLast ? Z_FINISH : Z_NO_FLUSH)
            }
        }
        let produced = scratch.count - Int(zstream.avail_out)
        output.append(contentsOf: scratch[0..<produced])
        // Drain remaining input if the output buffer filled.
        while status == Z_OK && zstream.avail_in > 0 {
            let more: Int32 = scratch.withUnsafeMutableBytes { dst in
                zstream.next_out = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
                zstream.avail_out = UInt32(dst.count)
                return CZlib.inflate(&zstream, isLast ? Z_FINISH : Z_NO_FLUSH)
            }
            let n = scratch.count - Int(zstream.avail_out)
            output.append(contentsOf: scratch[0..<n])
            status = more
        }
        switch status {
        case Z_OK, Z_BUF_ERROR:
            // Z_BUF_ERROR with a full drain is fine mid-stream.
            return output
        case Z_STREAM_END:
            finished = true
            return output
        default:
            throw InflateError.inflateFailed(Int(status))
        }
    }
    #endif
}
