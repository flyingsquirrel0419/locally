import Foundation
import LocallyCore

/// On-disk layout for partial downloads and installed models.
///
///     <root>/Downloads/partial/<jobID>/<sanitized relative path>.part
///     <root>/Downloads/resume/<jobID>/<fileIndex>.resume
///     <root>/Models/<org>_<name>/<revision>/<relativePath>
///     <root>/Models/<org>_<name>/<revision>/metadata.json
///
/// Partial and installed files are clearly separate; completion is an atomic
/// same-volume rename from the partial location to the installed location.
public struct FilesystemLayout: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Default layout under Application Support, for the app layer.
    public static func applicationSupport() -> FilesystemLayout {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share")
        return FilesystemLayout(root: base.appendingPathComponent("Locally", isDirectory: true))
    }

    public var downloadsRoot: URL { root.appendingPathComponent("Downloads", isDirectory: true) }
    public var modelsRoot: URL { root.appendingPathComponent("Models", isDirectory: true) }

    public func partialDirectory(jobID: UUID) -> URL {
        downloadsRoot.appendingPathComponent("partial", isDirectory: true)
            .appendingPathComponent(jobID.uuidString, isDirectory: true)
    }

    /// Partial file URL for one repo-relative path. `.part` is appended so an
    /// incomplete file can never be mistaken for an installed one.
    public func partialFileURL(jobID: UUID, relativePath: String) throws -> URL {
        try PathSanitizer.resolveUnder(base: partialDirectory(jobID: jobID),
                                       relative: relativePath)
            .appendingPathExtension("part")
    }

    public func resumeDirectory(jobID: UUID) -> URL {
        downloadsRoot.appendingPathComponent("resume", isDirectory: true)
            .appendingPathComponent(jobID.uuidString, isDirectory: true)
    }

    public func resumeDataURL(jobID: UUID, fileIndex: Int) -> URL {
        resumeDirectory(jobID: jobID).appendingPathComponent("\(fileIndex).resume")
    }

    /// Directory for one installed model. The repo id "org/name" becomes
    /// "org_name" so it is a single safe path component.
    public func modelDirectory(repoID: String, revision: String) -> URL {
        let safeID = repoID.replacingOccurrences(of: "/", with: "_")
        return modelsRoot.appendingPathComponent(safeID, isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
    }

    public func installedFileURL(repoID: String, revision: String, relativePath: String) throws -> URL {
        try PathSanitizer.resolveUnder(base: modelDirectory(repoID: repoID, revision: revision),
                                       relative: relativePath)
    }

    public func metadataURL(repoID: String, revision: String) -> URL {
        modelDirectory(repoID: repoID, revision: revision).appendingPathComponent("metadata.json")
    }

    @discardableResult
    public func createDirectories(for jobID: UUID) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: partialDirectory(jobID: jobID), withIntermediateDirectories: true)
        try fm.createDirectory(at: resumeDirectory(jobID: jobID), withIntermediateDirectories: true)
        return partialDirectory(jobID: jobID)
    }

    /// Removes everything a job left behind in Downloads/ (partials + resume data).
    public func removeJobArtifacts(jobID: UUID) {
        let fm = FileManager.default
        try? fm.removeItem(at: partialDirectory(jobID: jobID))
        try? fm.removeItem(at: resumeDirectory(jobID: jobID))
    }

    /// Atomically moves a completed part file into the installed model tree.
    /// Same-volume rename is atomic; both roots live under the same container.
    public func install(jobID: UUID, relativePath: String, repoID: String, revision: String) throws -> URL {
        let part = try partialFileURL(jobID: jobID, relativePath: relativePath)
        let destination = try installedFileURL(repoID: repoID, revision: revision, relativePath: relativePath)
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: part, to: destination)
        return destination
    }
}

/// Per-installed-model metadata written next to the model files.
public struct InstalledModelMetadata: Sendable, Codable {
    public var repoID: String
    public var revision: String
    public var files: [String: Int64]  // relativePath -> bytes
    public var installedAt: Date

    public init(repoID: String, revision: String, files: [String: Int64], installedAt: Date = Date()) {
        self.repoID = repoID
        self.revision = revision
        self.files = files
        self.installedAt = installedAt
    }
}
