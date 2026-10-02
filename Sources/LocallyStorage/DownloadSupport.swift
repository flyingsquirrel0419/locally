import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Linux)
import Glibc
#endif
import LocallyCore

/// Injectable clock for deterministic backoff tests.
public struct DownloadClock: Sendable {
    public var sleep: @Sendable (TimeInterval) async -> Void
    public var now: @Sendable () -> Date

    public init(sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.sleep = sleep
        self.now = now
    }
}

/// Injectable power state (iOS wires UIDevice battery state here).
public struct PowerStateProvider: Sendable {
    public var isCharging: @Sendable () -> Bool

    public init(isCharging: @escaping @Sendable () -> Bool = { true }) {
        self.isCharging = isCharging
    }
}

/// Injectable network-path check for download policy ("Wi-Fi only").
/// The iOS app wires a NWPathMonitor snapshot here; the default assumes a
/// usable connection so desktop/Linux/tests never block.
public struct NetworkPathProvider: Sendable {
    /// True when the current path is usable AND not a paid/limited interface
    /// (cellular, hotspot). An unknown path (no monitor snapshot yet) must
    /// return true — pausing on an unknown state would silently stall
    /// downloads on devices where the monitor has not published yet.
    public var isUsableWiFi: @Sendable () -> Bool

    public init(isUsableWiFi: @escaping @Sendable () -> Bool = { true }) {
        self.isUsableWiFi = isUsableWiFi
    }
}

/// One entry in the download diagnostics ring buffer (Settings →
/// Diagnostics). `detail` is a LocallyError technicalDetail or lifecycle
/// note; it never contains tokens or request headers.
public struct DownloadDiagnosticsEvent: Sendable, Hashable, Identifiable {
    public let id: Int
    public let timestamp: Date
    public let jobID: UUID?
    public let fileIndex: Int?
    public let detail: String

    public init(id: Int, timestamp: Date, jobID: UUID?, fileIndex: Int?, detail: String) {
        self.id = id
        self.timestamp = timestamp
        self.jobID = jobID
        self.fileIndex = fileIndex
        self.detail = detail
    }
}

/// Thread-safe ring buffer behind DownloadManager.recentDiagnostics.
public final class DownloadDiagnosticsLog: @unchecked Sendable {
    private struct State {
        var events: [DownloadDiagnosticsEvent] = []
        var nextID = 1
    }

    private let state = LockedState(State())
    private let capacity: Int

    public init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
    }

    public func record(_ detail: String, jobID: UUID? = nil, fileIndex: Int? = nil,
                       at date: Date = Date()) {
        state.withLock { s in
            s.events.append(DownloadDiagnosticsEvent(id: s.nextID, timestamp: date,
                                                     jobID: jobID, fileIndex: fileIndex,
                                                     detail: detail))
            s.nextID += 1
            if s.events.count > capacity {
                s.events.removeFirst(s.events.count - capacity)
            }
        }
    }

    /// Newest first.
    public func recent(limit: Int) -> [DownloadDiagnosticsEvent] {
        state.withLock { Array($0.events.suffix(limit).reversed()) }
    }
}

/// Injectable free-space probe so tests can simulate a nearly-full disk.
public struct FreeSpaceProvider: Sendable {
    public var freeBytes: @Sendable () -> Int64

    public init(freeBytes: @escaping @Sendable () -> Int64 = {
        #if os(Linux)
        // swift-corelibs-foundation lacks volume capacity keys, but statvfs
        // gives a real answer for the filesystem backing the home directory.
        return Self.linuxFreeBytes(path: NSHomeDirectory()) ?? .max
        #else
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else {
            return .max  // unknown: let the download attempt proceed
        }
        return capacity
        #endif
    }) {
        self.freeBytes = freeBytes
    }

    #if os(Linux)
    /// Bytes available to an unprivileged process on the filesystem that
    /// holds `path` (f_bavail × f_frsize). Nil when statvfs fails.
    public static func linuxFreeBytes(path: String) -> Int64? {
        var stats = statvfs()
        guard statvfs(path, &stats) == 0 else { return nil }
        let bytes = UInt64(stats.f_bavail) * UInt64(stats.f_frsize)
        return bytes > Int64.max ? .max : Int64(bytes)
    }
    #endif
}

/// Simple typed HTTP status error so transports can signal 4xx/5xx cleanly.
public struct HTTPStatusError: Error, Sendable, Hashable {
    public var statusCode: Int
    public init(statusCode: Int) { self.statusCode = statusCode }
}

extension DownloadState {
    /// Rebuilds a runtime state from a persisted file record.
    init(pausedPersisted file: DownloadFileTask) {
        switch file.state {
        case .queued: self = .queued
        case .preparing: self = .preparing
        case .downloading: self = .downloading(progress: file.progress)
        case .paused: self = .paused(resumeDataAvailable: file.hasResumeData)
        case .verifying: self = .verifying
        case .completed: self = .completed
        case .failed:
            self = .failed(.downloadFailed(userMessage: "The download failed.",
                                           technicalDetail: file.failureDetail ?? "unknown"))
        case .cancelled: self = .cancelled
        }
    }
}

extension DownloadManager {
    static func sha256Hex(of url: URL) throws -> String {
        var hasher = StreamingSHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(chunk)
        }
        return hasher.finalize()
    }

    static func mapError(_ error: Error) -> LocallyError {
        if let le = error as? LocallyError { return le }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return .network(userMessage: "The network connection failed.",
                            technicalDetail: "NSURLErrorDomain \(nsError.code)")
        }
        // Disk-full surfaced mid-write (POSIX ENOSPC) is a storage problem,
        // not a generic download failure — the user needs to free space.
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOSPC {
            return .insufficientStorage(
                userMessage: "Not enough storage. Free up space and retry the download.",
                technicalDetail: "ENOSPC while writing the download")
        }
        return .downloadFailed(userMessage: "The download failed.",
                               technicalDetail: String(describing: error))
    }

    /// 4xx auth failures are never retried automatically.
    static func isAuthFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && (nsError.code == NSURLErrorUserAuthenticationRequired) { return true }
        if let code = (error as? HTTPStatusError)?.statusCode { return code == 401 || code == 403 }
        return false
    }

    static func isNetworkish(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
    }

    /// A cancelled URLSession task is not a failure: the manager pauses the
    /// file and keeps any resume data instead of retrying. This covers both
    /// manager-initiated stops (guarded separately) and system-initiated
    /// cancellations (background task suspended, session invalidated).
    static func isCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return true }
        return error is CancellationError
    }
}
