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
