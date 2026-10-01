import Foundation
import LocallyCore

/// Streaming extraction plan for a ZIP archive: pure central-directory
/// parsing with hard safety limits. No archive bytes are inflated by the
/// planner, so hostile metadata can be rejected before any disk write.
///
/// Safety model (all enforced before writing anything):
/// - every entry name passes `PathSanitizer.sanitizeRepoPath` (rejects
///   "..", absolute paths, backslashes, NUL, drive-letter prefixes)
/// - symlink entries (unix mode S_IFLNK) and unsupported compression
///   methods are rejected
/// - entry count, total uncompressed bytes, and per-entry deflate ratio
///   are capped
public struct ZIPExtractionPlan: Sendable {

    public struct Entry: Sendable, Hashable {
        /// Repo-relative path, already sanitized.
        public var path: String
        /// Absolute offset of this entry's local header.
        public var localHeaderOffset: UInt64
        public var compressedSize: UInt64
        public var uncompressedSize: UInt64
        public var crc32: UInt32
        /// ZIP compression method: 0 = stored, 8 = deflate.
        public var method: UInt16
        public var isDirectory: Bool
    }

    public var entries: [Entry]

    /// Limits tuned for model resource archives (Core ML .mlmodelc trees):
    /// generous enough for multi-GB weight files, tight enough that a
    /// hostile archive trips a guard instead of filling the disk.
    public struct Limits: Sendable, Hashable {
        public var maxEntries: Int
        public var maxTotalUncompressedBytes: UInt64
        public var maxEntryUncompressedBytes: UInt64
        /// Reject deflated entries whose ratio exceeds this. Text files
        /// (vocab.json) compress ~4x; weights barely compress at all.
        public var maxCompressionRatio: Double

        public static let `default` = Limits(
            maxEntries: 5_000,
            maxTotalUncompressedBytes: 16 * 1024 * 1024 * 1024,
            maxEntryUncompressedBytes: 8 * 1024 * 1024 * 1024,
            maxCompressionRatio: 1_000
        )

        public init(maxEntries: Int, maxTotalUncompressedBytes: UInt64,
                    maxEntryUncompressedBytes: UInt64, maxCompressionRatio: Double) {
            self.maxEntries = maxEntries
            self.maxTotalUncompressedBytes = maxTotalUncompressedBytes
            self.maxEntryUncompressedBytes = maxEntryUncompressedBytes
            self.maxCompressionRatio = maxCompressionRatio
        }
    }

    public enum PlanError: Error, Sendable, Equatable {
        case notAZip
        case truncated
        case unsupportedFeature(String)
        case unsafeEntry(String)
        case limitExceeded(String)
    }

    /// Parse the archive at `url` (EOCD + central directory only) and return
    /// a validated extraction plan.
    public init(archiveAt url: URL, limits: Limits = .default) throws {
        let handle = FileHandle(forReadingAtPath: url.path)
        guard let handle else { throw PlanError.notAZip }
        defer { try? handle.close() }
        let fileSize = handle.seekToEndOfFile()
        guard fileSize >= 22 else { throw PlanError.notAZip }

        // EOCD: find the 0x06054b50 signature scanning backwards within the
        // maximum comment window (64 KiB + fixed record size).
        let window = min(fileSize, 65_557)
        let tailOffset = fileSize - window
        handle.seek(toFileOffset: tailOffset)
        let tail = handle.readData(ofLength: Int(window))
        guard let eocdOffset = Self.findEOCD(in: tail).map({ tailOffset + UInt64($0) }) else {
            throw PlanError.notAZip
        }
        handle.seek(toFileOffset: eocdOffset)
        let eocd = handle.readData(ofLength: 22)
        guard eocd.count == 22 else { throw PlanError.truncated }

        var entryCount = Int(Self.u16(eocd, 10))
        var cdSize = UInt64(Self.u32(eocd, 12))
        var cdOffset = UInt64(Self.u32(eocd, 16))

        // ZIP64: any saturated field means the real values live in the
        // ZIP64 EOCD locator/record right before the classic EOCD.
        if entryCount == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            guard eocdOffset >= 20 else { throw PlanError.truncated }
            handle.seek(toFileOffset: eocdOffset - 20)
            let locator = handle.readData(ofLength: 20)
            guard locator.count == 20, Self.u32(locator, 0) == 0x0706_4b50 else {
                throw PlanError.unsupportedFeature("zip64 locator missing")
            }
            let zip64Offset = Self.u64(locator, 8)
            handle.seek(toFileOffset: zip64Offset)
            let record = handle.readData(ofLength: 56)
            guard record.count == 56, Self.u32(record, 0) == 0x0606_4b50 else {
                throw PlanError.unsupportedFeature("zip64 eocd missing")
            }
            entryCount = Int(Self.u64(record, 32))
            cdSize = Self.u64(record, 40)
            cdOffset = Self.u64(record, 48)
        }

        guard entryCount <= limits.maxEntries else {
            throw PlanError.limitExceeded("entry count \(entryCount) exceeds \(limits.maxEntries)")
        }
        guard cdOffset + cdSize <= fileSize else { throw PlanError.truncated }

        handle.seek(toFileOffset: cdOffset)
        let cd = handle.readData(ofLength: Int(cdSize))
        guard cd.count == cdSize else { throw PlanError.truncated }

        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        var cursor = 0
        var totalUncompressed: UInt64 = 0

        for _ in 0..<entryCount {
            guard cursor + 46 <= cd.count, Self.u32(cd, cursor) == 0x0201_4b50 else {
                throw PlanError.truncated
            }
            let flags = Self.u16(cd, cursor + 8)
            let method = Self.u16(cd, cursor + 10)
            let crc = Self.u32(cd, cursor + 16)
            var compressed = UInt64(Self.u32(cd, cursor + 20))
            var uncompressed = UInt64(Self.u32(cd, cursor + 24))
            let nameLength = Int(Self.u16(cd, cursor + 28))
            let extraLength = Int(Self.u16(cd, cursor + 30))
            let commentLength = Int(Self.u16(cd, cursor + 32))
            let externalAttrs = Self.u32(cd, cursor + 38)
            var localOffset = UInt64(Self.u32(cd, cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= cd.count else { throw PlanError.truncated }
            let nameData = cd.subdata(in: nameStart..<(nameStart + nameLength))
            guard let rawName = String(data: nameData, encoding: .utf8) else {
                throw PlanError.unsafeEntry("entry name is not valid UTF-8")
            }
            let extraStart = nameStart + nameLength
            guard extraStart + extraLength <= cd.count else { throw PlanError.truncated }

            // ZIP64 extra field (0x0001) supplies saturated sizes/offsets.
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF
                || localOffset == 0xFFFF_FFFF {
                let extra = cd.subdata(in: extraStart..<(extraStart + extraLength))
                var e = 0
                var found = false
                while e + 4 <= extra.count {
                    let headerID = Self.u16(extra, e)
                    let size = Int(Self.u16(extra, e + 2))
                    e += 4
                    guard e + size <= extra.count else { break }
                    if headerID == 0x0001 {
                        var p = e
                        if uncompressed == 0xFFFF_FFFF, p + 8 <= e + size {
                            uncompressed = Self.u64(extra, p); p += 8
                        }
                        if compressed == 0xFFFF_FFFF, p + 8 <= e + size {
                            compressed = Self.u64(extra, p); p += 8
                        }
                        if localOffset == 0xFFFF_FFFF, p + 8 <= e + size {
                            localOffset = Self.u64(extra, p)
                        }
                        found = true
                        break
                    }
                    e += size
                }
                guard found else { throw PlanError.unsupportedFeature("zip64 extra field missing") }
            }

            cursor = extraStart + extraLength + commentLength

            // Symlinks and other non-regular entries are never written.
            let unixMode = externalAttrs >> 16
            let fileType = unixMode & 0o170000
            if fileType == 0o120000 { // S_IFLNK
                throw PlanError.unsafeEntry("symlink entry: \(rawName)")
            }

            let isDirectory = rawName.hasSuffix("/")
            guard method == 0 || method == 8 || isDirectory else {
                throw PlanError.unsupportedFeature("compression method \(method) for \(rawName)")
            }
            // Encrypted entries (bit 0) cannot be verified; data descriptors
            // (bit 3) are fine — the central directory carries real sizes.
            guard flags & 0x1 == 0 else {
                throw PlanError.unsupportedFeature("encrypted entry: \(rawName)")
            }

            let path = try Self.sanitize(name: rawName, isDirectory: isDirectory)

            if !isDirectory {
                guard uncompressed <= limits.maxEntryUncompressedBytes else {
                    throw PlanError.limitExceeded(
                        "entry \(rawName) exceeds \(limits.maxEntryUncompressedBytes) bytes")
                }
                if method == 8, compressed > 0 {
                    let ratio = Double(uncompressed) / Double(compressed)
                    guard ratio <= limits.maxCompressionRatio else {
                        throw PlanError.limitExceeded(
                            "entry \(rawName) compression ratio \(Int(ratio)):1 is implausible")
                    }
                }
                totalUncompressed += uncompressed
                guard totalUncompressed <= limits.maxTotalUncompressedBytes else {
                    throw PlanError.limitExceeded(
                        "archive exceeds \(limits.maxTotalUncompressedBytes) bytes total")
                }
            }
            entries.append(Entry(path: path, localHeaderOffset: localOffset,
                                 compressedSize: compressed, uncompressedSize: uncompressed,
                                 crc32: crc, method: isDirectory ? 0 : method,
                                 isDirectory: isDirectory))
        }
        self.entries = entries
    }

    /// Reject traversal, absolute paths, drive letters; directory entries
    /// pass without the trailing slash rule of repo paths.
    private static func sanitize(name: String, isDirectory: Bool) throws -> String {
        let trimmed = isDirectory ? String(name.dropLast()) : name
        // Drive letters ("C:...") and UNC-ish prefixes.
        if trimmed.count >= 2 {
            let second = trimmed.index(trimmed.startIndex, offsetBy: 1)
            if trimmed[second] == ":" { throw PlanError.unsafeEntry("drive-letter path: \(name)") }
        }
        do {
            return try PathSanitizer.sanitizeRepoPath(trimmed)
        } catch {
            throw PlanError.unsafeEntry("unsafe path: \(name)")
        }
    }

    static func findEOCD(in data: Data) -> Int? {
        let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        guard data.count >= signature.count else { return nil }
        var i = data.count - signature.count
        while true {
            if data[i] == signature[0], data[i + 1] == signature[1],
               data[i + 2] == signature[2], data[i + 3] == signature[3] {
                return i
            }
            if i == 0 { return nil }
            i -= 1
        }
    }

    static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    static func u64(_ data: Data, _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(data[offset + i]) << UInt64(8 * i) }
        return value
    }
}

/// Executes a ZIPExtractionPlan: streams each entry from the archive,
/// inflates when needed, verifies CRC-32, and writes under `destination`.
/// The whole archive is never loaded into memory.
public struct ZIPExtractor: Sendable {

    public enum ExtractError: Error, Sendable {
        case badLocalHeader(String)
        case crcMismatch(String)
        case sizeMismatch(String)
        case inflateFailed(String)
        case ioFailed(String)
    }

    private static let chunkSize = 512 * 1024

    public init() {}

    /// Extract every planned entry under `destination`. On failure the
    /// partially-written entry file is removed; earlier entries stay.
    public func extract(archiveAt archiveURL: URL, plan: ZIPExtractionPlan,
                        to destination: URL) throws {
        let fm = FileManager.default
        for entry in plan.entries {
            let target = try PathSanitizer.resolveUnder(base: destination, relative: entry.path)
            if entry.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            do {
                try extractEntry(entry, from: archiveURL, to: target)
            } catch {
                try? fm.removeItem(at: target)
                throw error
            }
        }
    }

    private func extractEntry(_ entry: ZIPExtractionPlan.Entry,
                              from archiveURL: URL, to target: URL) throws {
        guard let reader = FileHandle(forReadingAtPath: archiveURL.path) else {
            throw ExtractError.ioFailed("cannot open archive \(archiveURL.path)")
        }
        defer { try? reader.close() }

        // Local header: variable-length, so parse to find the data start.
        reader.seek(toFileOffset: entry.localHeaderOffset)
        let header = reader.readData(ofLength: 30)
        guard header.count == 30, ZIPExtractionPlan.u32(header, 0) == 0x0403_4b50 else {
            throw ExtractError.badLocalHeader(entry.path)
        }
        let nameLength = Int(ZIPExtractionPlan.u16(header, 26))
        let extraLength = Int(ZIPExtractionPlan.u16(header, 28))
        let dataStart = entry.localHeaderOffset + 30 + UInt64(nameLength) + UInt64(extraLength)

        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
            throw ExtractError.ioFailed("cannot create \(target.path)")
        }
        guard let writer = FileHandle(forWritingAtPath: target.path) else {
            throw ExtractError.ioFailed("cannot write \(target.path)")
        }
        defer { try? writer.close() }

        var crc = CRC32()
        var written: UInt64 = 0
        var consumed: UInt64 = 0

        // Stored entries could technically be read in one pass, but the same
        // chunked loop keeps memory bounded either way.
        var inflater: Inflater? = nil
        let isDeflated = entry.method == 8

        while consumed < entry.compressedSize {
            let length = Int(min(UInt64(Self.chunkSize), entry.compressedSize - consumed))
            reader.seek(toFileOffset: dataStart + consumed)
            let chunk = reader.readData(ofLength: length)
            guard chunk.count == length else {
                throw ExtractError.sizeMismatch("unexpected EOF in \(entry.path)")
            }
            consumed += UInt64(chunk.count)

            if isDeflated {
                if inflater == nil { inflater = try Inflater() }
                let isLast = consumed == entry.compressedSize
                let output = try inflater!.inflate(chunk, isLast: isLast, path: entry.path)
                crc.update(output)
                try writeAll(writer, output)
                written += UInt64(output.count)
            } else {
                crc.update(chunk)
                try writeAll(writer, chunk)
                written += UInt64(chunk.count)
            }
        }
        guard written == entry.uncompressedSize else {
            throw ExtractError.sizeMismatch(
                "\(entry.path): got \(written) bytes, expected \(entry.uncompressedSize)")
        }
        guard crc.value == entry.crc32 else {
            throw ExtractError.crcMismatch(entry.path)
        }
    }

    /// The central directory carries the method; no local-header re-read.
    private func writeAll(_ handle: FileHandle, _ data: Data) throws {
        do { try handle.write(contentsOf: data) } catch {
            throw ExtractError.ioFailed("write failed: \(error)")
        }
    }
}
