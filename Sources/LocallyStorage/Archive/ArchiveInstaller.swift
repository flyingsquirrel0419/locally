import Foundation
import LocallyCore

/// Post-download archive handling for the install pipeline: when a required
/// file is a `.zip` (Core ML diffusion repos ship compiled model folders as
/// per-variant archives), extract it into the model directory and remove the
/// archive. Extraction goes through ZIPExtractionPlan's safety limits, so a
/// hostile archive fails before writing anything outside the model dir.
public struct ArchiveInstaller: Sendable {

    public init() {}

    /// Expand any installed `.zip` files inside `directory`, in place.
    /// Returns the relative paths of the extracted archives. Extraction
    /// happens off the caller's thread pool; archives are deleted only after
    /// a fully successful extraction.
    @discardableResult
    public func extractArchives(in directory: URL) throws -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        var archives: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "zip",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            archives.append(url)
        }

        var extracted: [String] = []
        for archive in archives {
            let plan = try ZIPExtractionPlan(archiveAt: archive)
            try ZIPExtractor().extract(archiveAt: archive, plan: plan, to: directory)
            try fm.removeItem(at: archive)
            let relative = archive.path.hasPrefix(directory.path + "/")
                ? String(archive.path.dropFirst(directory.path.count + 1))
                : archive.lastPathComponent
            extracted.append(relative)
        }
        return extracted
    }
}
