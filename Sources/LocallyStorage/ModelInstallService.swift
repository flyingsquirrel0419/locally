import Foundation
import LocallyCore

/// Turns an analyzed ModelDescriptor into a DownloadJob and, once the job
/// completes, registers the InstalledModel. Lives in LocallyStorage and
/// takes plain descriptors — no LocallyHF dependency; the HF URL scheme is
/// fixed here so URLs are never taken from remote data.
public actor ModelInstallService {
    /// Reads the auth header at request time so token changes apply to
    /// in-flight scheduling. Return nil when no token is stored.
    public typealias AuthHeaderProvider = @Sendable () throws -> String?

    private let downloadManager: DownloadManager
    private let registry: ModelRegistry
    private let authHeaderProvider: AuthHeaderProvider?
    private var watchTasks: [UUID: Task<Void, Never>] = [:]

    public init(downloadManager: DownloadManager, registry: ModelRegistry,
                authHeaderProvider: AuthHeaderProvider? = nil) {
        self.downloadManager = downloadManager
        self.registry = registry
        self.authHeaderProvider = authHeaderProvider
    }

    /// Authorization header value for one URL, read fresh per call.
    /// Only HF hosts ever see a value.
    public func authorizationHeader(for url: URL) -> String? {
        guard let host = url.host, RedirectPolicy.isAllowedHFHost(host),
              let provider = authHeaderProvider,
              let token = try? provider(), !token.isEmpty else { return nil }
        return "Bearer \(token)"
    }

    /// Build download sources from a descriptor: HTTPS resolve URLs pinned to
    /// the given revision, sha256 from LFS metadata when present.
    public func sources(for descriptor: ModelDescriptor, revision: String) throws -> [DownloadSource] {
        guard !descriptor.requiredFiles.isEmpty else {
            throw LocallyError.downloadFailed(
                userMessage: "This repository has no downloadable model files.",
                technicalDetail: "requiredFiles is empty for \(descriptor.repoID)")
        }
        return try descriptor.requiredFiles.map { file in
            let safe = try PathSanitizer.sanitizeRepoPath(file.path)
            let escaped = safe.split(separator: "/", omittingEmptySubsequences: false)
                .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
                .joined(separator: "/")
            // urlPathAllowed keeps "/" unescaped; revisions like "refs/pr/7"
            // would otherwise change the URL's path shape.
            var revisionCharset = CharacterSet.urlPathAllowed
            revisionCharset.remove(charactersIn: "/")
            let revisionEscaped = revision.addingPercentEncoding(withAllowedCharacters: revisionCharset) ?? revision
            guard let url = URL(string: "https://huggingface.co/\(descriptor.repoID)/resolve/\(revisionEscaped)/\(escaped)") else {
                throw LocallyError.network(
                    userMessage: "Couldn't build the download address for one of the files.",
                    technicalDetail: "URL build failed for \(descriptor.repoID)/\(file.path)")
            }
            return DownloadSource(url: url, relativePath: safe,
                                  expectedSize: file.size, sha256: file.sha256)
        }
    }

    /// Enqueue the download and arm a completion watch that registers the
    /// model in the registry once every file lands and verifies.
    @discardableResult
    public func install(descriptor: ModelDescriptor, revision: String,
                        policy: DownloadPolicy = .init()) async throws -> DownloadJob {
        let sources = try sources(for: descriptor, revision: revision)
        let job = try await downloadManager.enqueue(repoID: descriptor.repoID,
                                                    revision: revision,
                                                    sources: sources,
                                                    policy: policy)
        watch(jobID: job.id, descriptor: descriptor, revision: revision)
        return job
    }

    /// Poll the store until the job finishes; on success register the model.
    /// Polling keeps this independent of transport event plumbing; the
    /// interval is slow because completion is a once-per-install event.
    private func watch(jobID: UUID, descriptor: ModelDescriptor, revision: String) {
        let task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let job = try? await self.downloadManager.jobs().first(where: { $0.id == jobID }) else {
                    return  // job cancelled/removed; nothing to register
                }
                if job.files.allSatisfy({ $0.state == .completed }) {
                    let model = InstalledModel(repoID: descriptor.repoID, revision: revision,
                                               descriptor: descriptor,
                                               sizeOnDisk: job.totalBytes)
                    try? await self.registry.register(model)
                    return
                }
                if job.isFinished { return }  // failed or cancelled: no registration
            }
        }
        watchTasks[jobID] = task
    }
}
