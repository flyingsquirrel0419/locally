import Foundation

/// A single file to fetch from a remote host. Deliberately defined here so
/// LocallyStorage does not depend on LocallyHF; the app layer maps HF URLs
/// into this struct and injects the auth header at request time.
public struct DownloadSource: Sendable, Hashable {
    public var url: URL
    public var relativePath: String
    public var expectedSize: Int64
    public var sha256: String?

    public init(url: URL, relativePath: String, expectedSize: Int64, sha256: String? = nil) {
        self.url = url
        self.relativePath = relativePath
        self.expectedSize = expectedSize
        self.sha256 = sha256
    }
}

/// Download scheduling policy for a job.
public struct DownloadPolicy: Sendable, Hashable, Codable {
    public var allowsCellular: Bool
    public var onlyWhileCharging: Bool

    public init(allowsCellular: Bool = false, onlyWhileCharging: Bool = false) {
        self.allowsCellular = allowsCellular
        self.onlyWhileCharging = onlyWhileCharging
    }
}

/// One file inside a job, with its own state and resume-data bookkeeping.
/// Resume data is stored as a separate file on disk; only its relative
/// filename lives in the persisted JSON.
public struct DownloadFileTask: Sendable, Hashable, Codable {
    public var relativePath: String
    public var expectedSize: Int64
    public var sha256: String?
    public var bytesReceived: Int64
    public var resumeDataFile: String?
    public var attempts: Int

    /// Persisted representation of DownloadState (associated values flattened).
    public enum PersistedState: String, Sendable, Codable {
        case queued, preparing, downloading, paused, verifying, completed, failed, cancelled
    }

    public var state: PersistedState
    public var progress: Double
    public var hasResumeData: Bool
    public var failureDetail: String?

    public init(relativePath: String, expectedSize: Int64, sha256: String?) {
        self.relativePath = relativePath
        self.expectedSize = expectedSize
        self.sha256 = sha256
        self.bytesReceived = 0
        self.resumeDataFile = nil
        self.attempts = 0
        self.state = .queued
        self.progress = 0
        self.hasResumeData = false
        self.failureDetail = nil
    }
}

/// A persistent download job: all files of one model at one revision.
public struct DownloadJob: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var modelRepoID: String
    public var revision: String
    public var files: [DownloadFileTask]
    public var totalBytes: Int64
    public var createdAt: Date
    public var policy: DownloadPolicy

    public init(id: UUID = UUID(), modelRepoID: String, revision: String,
                files: [DownloadFileTask], policy: DownloadPolicy = .init(),
                createdAt: Date = Date()) {
        self.id = id
        self.modelRepoID = modelRepoID
        self.revision = revision
        self.files = files
        self.totalBytes = files.reduce(0) { $0 + $1.expectedSize }
        self.createdAt = createdAt
        self.policy = policy
    }

    public var isFinished: Bool {
        files.allSatisfy { $0.state == .completed || $0.state == .cancelled || $0.state == .failed }
    }

    public var bytesDownloaded: Int64 {
        files.reduce(0) { $0 + $1.bytesReceived }
    }

    /// Aggregate state shown in the UI. Failed dominates, then downloading,
    /// then paused, then completed, otherwise queued.
    public var aggregateState: DownloadFileTask.PersistedState {
        if files.contains(where: { $0.state == .failed }) { return .failed }
        if files.contains(where: { $0.state == .cancelled }) { return .cancelled }
        if files.contains(where: { $0.state == .downloading || $0.state == .preparing || $0.state == .verifying }) { return .downloading }
        if files.contains(where: { $0.state == .paused }) { return .paused }
        if files.allSatisfy({ $0.state == .completed }) { return .completed }
        return .queued
    }
}
