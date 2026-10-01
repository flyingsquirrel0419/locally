import Foundation
import LocallyCore

/// Actor that persists DownloadJobs as JSON with atomic writes.
/// Layout: <directory>/jobs.json. Resume data lives in separate files and is
/// referenced by filename only.
public actor DownloadStore {
    private let directory: URL
    private var jobs: [DownloadJob] = []
    private var loaded = false

    public init(directory: URL) {
        self.directory = directory
    }

    private var jobsFile: URL { directory.appendingPathComponent("jobs.json") }

    private func ensureLoaded() throws {
        guard !loaded else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: jobsFile.path) {
            let data = try Data(contentsOf: jobsFile)
            jobs = try JSONDecoder().decode([DownloadJob].self, from: data)
        }
        loaded = true
    }

    /// Atomic write: serialize to a sibling temp file, then rename over the
    /// target. rename(2) is atomic on POSIX for same-directory renames.
    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(jobs)
        let tmp = directory.appendingPathComponent("jobs.json.tmp")
        try data.write(to: tmp)
        let fm = FileManager.default
        if fm.fileExists(atPath: jobsFile.path) {
            try fm.removeItem(at: jobsFile)
        }
        try fm.moveItem(at: tmp, to: jobsFile)
    }

    public func allJobs() throws -> [DownloadJob] {
        try ensureLoaded()
        return jobs
    }

    public func job(id: UUID) throws -> DownloadJob? {
        try ensureLoaded()
        return jobs.first { $0.id == id }
    }

    @discardableResult
    public func upsert(_ job: DownloadJob) throws -> DownloadJob {
        try ensureLoaded()
        if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[idx] = job
        } else {
            jobs.append(job)
        }
        try persist()
        return job
    }

    public func remove(id: UUID) throws {
        try ensureLoaded()
        jobs.removeAll { $0.id == id }
        try persist()
    }
}
