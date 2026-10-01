import Foundation
import LocallyCore

/// Guards against path traversal in remote file paths before they touch disk.
/// Week 3's FilesystemLayout and DownloadManager route every repo-relative
/// path through this.
public enum PathSanitizer {
    /// Returns the path unchanged when safe, throws otherwise.
    /// Rejects absolute paths, ".." components, empty components, backslashes,
    /// and NUL bytes.
    public static func sanitizeRepoPath(_ path: String) throws -> String {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/"),
              !path.contains("\0"), !path.contains("\\"), !path.contains("//") else {
            throw LocallyError.pathTraversal(technicalDetail: "unsafe path: \(path)")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != ".." && $0 != "." && !$0.isEmpty }) else {
            throw LocallyError.pathTraversal(technicalDetail: "unsafe path: \(path)")
        }
        return path
    }

    /// Joins a sanitized relative path under `base` and verifies the resolved
    /// path still lives inside `base`.
    public static func resolveUnder(base: URL, relative path: String) throws -> URL {
        let safe = try sanitizeRepoPath(path)
        let resolved = base.appendingPathComponent(safe, isDirectory: false).standardizedFileURL
        let basePath = base.standardizedFileURL.path
        guard resolved.path == basePath || resolved.path.hasPrefix(basePath + "/") else {
            throw LocallyError.pathTraversal(technicalDetail: "escaped base: \(path)")
        }
        return resolved
    }
}
