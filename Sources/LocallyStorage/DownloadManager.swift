import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LocallyCore

/// Manages all download jobs: scheduling, persistence, retry, policy.
/// Transport-injectable so tests drive it with a mock.
public actor DownloadManager {
    /// Why a job or file was paused by the manager (as opposed to the user).
    public enum PauseReason: String, Sendable {
        case user, unplugged, networkPolicy
    }

    public static let maxAutomaticRetries = 3

    private let store: DownloadStore
    private let layout: FilesystemLayout
    private let transport: any DownloadTransport
    private let authHeaderProvider: @Sendable (URL) -> String?
    private let clock: DownloadClock
    private let power: PowerStateProvider
    private let network: NetworkPathProvider
    private let freeSpace: FreeSpaceProvider
    /// Ring buffer of recent events for the in-app Diagnostics screen.
    private let diagnostics = DownloadDiagnosticsLog()

    public private(set) var concurrentFileLimit: Int
    private var runningCount = 0
    private var transferToFile: [DownloadTransport.TransferID: (UUID, Int)] = [:]
    /// Transfers the manager itself stopped (pause/cancel). A real URLSession
    /// still delivers didCompleteWithError(NSURLErrorCancelled) and late
    /// progress callbacks for a cancelled task; without this set those events
    /// would be handled as failures and the auto-retry would restart a
    /// transfer the user explicitly stopped.
    private var intentionallyStopped: Set<DownloadTransport.TransferID> = []
    /// Jobs being torn down by cancel(). Actor reentrancy lets an in-flight
    /// event handler or queue pump run between cancel's awaits; without this
    /// tombstone such a path could upsert the job back after it was removed.
    private var tombstonedJobs: Set<UUID> = []
    private var eventTask: Task<Void, Never>?

    public init(store: DownloadStore, layout: FilesystemLayout, transport: any DownloadTransport,
                authHeaderProvider: @escaping @Sendable (URL) -> String? = { _ in nil },
                clock: DownloadClock = .init(), power: PowerStateProvider = .init(),
                network: NetworkPathProvider = .init(),
                freeSpace: FreeSpaceProvider = .init(), concurrentFileLimit: Int = 2) {
        self.store = store
        self.layout = layout
        self.transport = transport
        self.authHeaderProvider = authHeaderProvider
        self.clock = clock
        self.power = power
        self.network = network
        self.freeSpace = freeSpace
        self.concurrentFileLimit = max(1, concurrentFileLimit)
    }

    public func setConcurrentFileLimit(_ limit: Int) {
        concurrentFileLimit = max(1, limit)
    }

    // MARK: - Job lifecycle

    /// Create and persist a new job, then start scheduling its files.
    @discardableResult
    public func enqueue(repoID: String, revision: String, sources: [DownloadSource],
                        policy: DownloadPolicy = .init()) async throws -> DownloadJob {
        var files: [DownloadFileTask] = []
        for source in sources {
            _ = try PathSanitizer.sanitizeRepoPath(source.relativePath)
            files.append(DownloadFileTask(relativePath: source.relativePath,
                                          expectedSize: source.expectedSize,
                                          sha256: source.sha256))
        }
        let job = DownloadJob(modelRepoID: repoID, revision: revision, files: files, policy: policy)
        _ = try await store.upsert(job)
        try layout.createDirectories(for: job.id)
        await startEventPump()
        // Stash URLs in memory only; re-supplied via registerSources after relaunch.
        sourceRegistry[job.id] = sources
        diagnostics.record("enqueued \(sources.count) file(s) for \(repoID)@\(revision)", jobID: job.id)
        schedule()
        return job
    }

    /// The manager keeps URLs in memory only. After relaunch the app must
    /// re-supply them; until then affected files stay paused.
    private var sourceRegistry: [UUID: [DownloadSource]] = [:]

    public func registerSources(_ sources: [DownloadSource], for jobID: UUID) {
        guard !tombstonedJobs.contains(jobID) else { return }
        sourceRegistry[jobID] = sources
        schedule()
    }

    public func jobs() async throws -> [DownloadJob] {
        try await store.allJobs()
    }

    public func pause(jobID: UUID) async throws {
        guard !tombstonedJobs.contains(jobID) else { return }
        guard var job = try await store.job(id: jobID) else { return }
        for index in job.files.indices {
            let current = DownloadState(pausedPersisted: job.files[index])
            let next = DownloadReducer.reduce(current, .pause(resumeDataAvailable: false))
            apply(next, to: &job.files[index])
            if case .paused = next {
                job.files[index].pauseReason = PauseReason.user.rawValue
                if let (transferID, _) = runningTransfers(for: jobID, fileIndex: index).first {
                    // Detach BEFORE awaiting the transport: the cancellation
                    // callback (NSURLErrorCancelled, with resume data on
                    // URLSession) is delivered asynchronously and must not be
                    // treated as a retryable failure.
                    transferToFile.removeValue(forKey: transferID)
                    intentionallyStopped.insert(transferID)
                    runningCount = max(0, runningCount - 1)
                    if let data = await transport.pause(transferID) {
                        try saveResumeData(data, jobID: jobID, fileIndex: index)
                        job.files[index].hasResumeData = true
                    }
                }
            }
        }
        guard !tombstonedJobs.contains(jobID) else { return }
        _ = try await store.upsert(job)
        diagnostics.record("paused by user", jobID: jobID)
    }

    public func resume(jobID: UUID) async throws {
        guard !tombstonedJobs.contains(jobID) else { return }
        guard var job = try await store.job(id: jobID) else { return }
        for index in job.files.indices where job.files[index].state == .paused {
            // Resume goes through the reducer (paused -> queued) so the
            // scheduling pump owns the queued -> preparing -> downloading path.
            let current = DownloadState(pausedPersisted: job.files[index])
            apply(DownloadReducer.reduce(current, .resume), to: &job.files[index])
            job.files[index].progress = 0
            job.files[index].pauseReason = nil
        }
        _ = try await store.upsert(job)
        schedule()
    }

    public func cancel(jobID: UUID) async throws {
        // Tombstone FIRST: actor reentrancy means a queued-up event handler
        // or schedule pump can run at any await below; every read/upsert
        // path checks this set so the job cannot reappear once removed.
        tombstonedJobs.insert(jobID)
        guard var job = try await store.job(id: jobID) else {
            tombstonedJobs.remove(jobID)
            return
        }
        for index in job.files.indices {
            let current = DownloadState(pausedPersisted: job.files[index])
            apply(DownloadReducer.reduce(current, .cancel), to: &job.files[index])
            if let (transferID, _) = runningTransfers(for: jobID, fileIndex: index).first {
                transferToFile.removeValue(forKey: transferID)
                intentionallyStopped.insert(transferID)
                runningCount = max(0, runningCount - 1)
                await transport.cancel(transferID)
            }
        }
        layout.removeJobArtifacts(jobID: jobID)
        sourceRegistry.removeValue(forKey: jobID)
        try await store.remove(id: jobID)
        diagnostics.record("cancelled; partial files deleted", jobID: jobID)
        tombstonedJobs.remove(jobID)
    }

    /// Re-enqueue failed files for another automatic or manual attempt.
    /// Verification failures (size/sha) already deleted the part file; for
    /// transport failures any leftover partial bytes belong to an attempt
    /// whose integrity is unknown — the next start begins from offset 0,
    /// so the stale part must be dropped or the fresh bytes would append
    /// onto garbage and fail verification again.
    public func retry(jobID: UUID) async throws {
        guard !tombstonedJobs.contains(jobID) else { return }
        guard var job = try await store.job(id: jobID) else { return }
        for index in job.files.indices where job.files[index].state == .failed {
            let current = DownloadState(pausedPersisted: job.files[index])
            apply(DownloadReducer.reduce(current, .enqueue), to: &job.files[index])
            job.files[index].attempts += 1
            job.files[index].failureDetail = nil
            job.files[index].failureUserMessage = nil
            job.files[index].bytesReceived = 0
            job.files[index].hasResumeData = false
            if let part = try? layout.partialFileURL(jobID: jobID,
                                                     relativePath: job.files[index].relativePath) {
                try? FileManager.default.removeItem(at: part)
            }
            try? FileManager.default.removeItem(at: layout.resumeDataURL(jobID: jobID, fileIndex: index))
        }
        _ = try await store.upsert(job)
        schedule()
    }

    // MARK: - Restore after relaunch

    /// Reconcile persisted state after the process restarts: anything that
    /// was mid-flight becomes paused (bytes on disk are kept; resume data
    /// files are still valid). The app re-registers sources and calls resume.
    public func restore() async throws {
        let jobs = try await store.allJobs()
        for var job in jobs {
            var changed = false
            for index in job.files.indices {
                switch job.files[index].state {
                case .downloading, .preparing, .verifying:
                    let current = DownloadState(pausedPersisted: job.files[index])
                    apply(DownloadReducer.reduce(current, .pause(resumeDataAvailable: job.files[index].hasResumeData)),
                          to: &job.files[index])
                    changed = true
                default:
                    break
                }
            }
            if changed { _ = try await store.upsert(job) }
        }
        await startEventPump()
        // Tasks iOS kept alive across the relaunch still stream events;
        // rebind them to their persisted job files via the task key.
        for key in await transport.reattachedTransfers() {
            guard let parsed = Self.parseTaskKey(key) else { continue }
            diagnostics.record("reattached transfer after relaunch",
                               jobID: parsed.jobID, fileIndex: parsed.fileIndex)
        }
    }

    /// "<jobID>|<fileIndex>" ↔ tuple, for transport task keys.
    public static func taskKey(jobID: UUID, fileIndex: Int) -> String {
        "\(jobID.uuidString)|\(fileIndex)"
    }

    public static func parseTaskKey(_ key: String) -> (jobID: UUID, fileIndex: Int)? {
        let parts = key.split(separator: "|")
        guard parts.count == 2, let jobID = UUID(uuidString: String(parts[0])),
              let fileIndex = Int(parts[1]) else { return nil }
        return (jobID, fileIndex)
    }

    // MARK: - Scheduling

    private var pumping = false
    private var pumpAgain = false

    private func schedule() {
        Task { await self.pumpQueue() }
    }

    /// Serialized queue pump: concurrent schedule() calls coalesce, and a
    /// schedule arriving mid-pump triggers exactly one more pass.
    private func pumpQueue() async {
        if pumping {
            pumpAgain = true
            return
        }
        pumping = true
        repeat {
            pumpAgain = false
            await pumpOnce()
        } while pumpAgain
        pumping = false
    }

    private func pumpOnce() async {
        do {
            let jobs = try await store.allJobs()
            for job in jobs where !job.isFinished {
                if tombstonedJobs.contains(job.id) { continue }
                if job.policy.onlyWhileCharging && !power.isCharging() {
                    try await pauseForPolicy(jobID: job.id, reason: .unplugged)
                    continue
                }
                if !job.policy.allowsCellular && !network.isUsableWiFi() {
                    try await pauseForPolicy(jobID: job.id, reason: .networkPolicy)
                    continue
                }
                guard let sources = sourceRegistry[job.id] else { continue }
                for index in job.files.indices where job.files[index].state == .queued {
                    guard runningCount < concurrentFileLimit else { return }
                    try await startFile(job: job, fileIndex: index, sources: sources)
                }
            }
        } catch {
            Log.error(.download, "queue pump failed: \(error.localizedDescription)")
        }
    }

    private func startFile(job: DownloadJob, fileIndex: Int, sources: [DownloadSource]) async throws {
        guard !tombstonedJobs.contains(job.id) else { return }
        guard var fresh = try await store.job(id: job.id) else { return }
        guard fileIndex < sources.count, fileIndex < fresh.files.count else { return }
        // Atomicity guard: skip if another path already moved it off .queued.
        guard fresh.files[fileIndex].state == .queued else { return }
        let source = sources[fileIndex]
        var file = fresh.files[fileIndex]

        // Storage preflight: re-check before every file. Overhead model is
        // 1.0x (we rename in place, no copy) plus headroom: max(512 MB, 5%).
        let remaining = max(0, source.expectedSize - file.bytesReceived)
        let headroom = max(512 * 1024 * 1024, source.expectedSize / 20)
        let required = remaining + headroom
        let available = freeSpace.freeBytes()
        guard available == .max || available >= required else {
            let needGB = String(format: "%.1f", Double(required) / 1e9)
            let haveGB = String(format: "%.1f", Double(available) / 1e9)
            let error = LocallyError.insufficientStorage(
                userMessage: "Not enough storage. This download needs \(needGB) GB free; you have \(haveGB) GB.",
                technicalDetail: "required=\(required) available=\(available)")
            apply(DownloadReducer.reduce(.queued, .prepare), to: &file)
            apply(DownloadReducer.reduce(DownloadState(pausedPersisted: file), .fail(error)), to: &file)
            fresh.files[fileIndex] = file
            _ = try await store.upsert(fresh)
            diagnostics.record("storage preflight failed for \(source.relativePath): \(error.technicalDetail)",
                               jobID: job.id, fileIndex: fileIndex)
            return
        }

        let partURL = try layout.partialFileURL(jobID: job.id, relativePath: source.relativePath)
        try FileManager.default.createDirectory(at: partURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        apply(DownloadReducer.reduce(.queued, .prepare), to: &file)
        apply(DownloadReducer.reduce(DownloadState(pausedPersisted: file), .start), to: &file)
        fresh.files[fileIndex] = file
        _ = try await store.upsert(fresh)
        guard !tombstonedJobs.contains(job.id) else { return }

        var request = URLRequest(url: source.url)
        // Model bytes must arrive untranscoded so size and sha256 match the
        // remote object; also keeps Range semantics byte-exact.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let header = authHeaderProvider(source.url) {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        let resumeData = file.hasResumeData ? loadResumeData(jobID: job.id, fileIndex: fileIndex) : nil
        // HTTP Range resume is for continuing a partially-downloaded file —
        // i.e. an attempt that already transferred bytes (bytesReceived > 0)
        // or an explicit resume with resume data on hand. A stale part file
        // from a failed attempt whose integrity is unknown must be replaced
        // by a fresh full download, not appended onto.
        let isResume = file.bytesReceived > 0 || resumeData != nil
        let partSize = Int64((try? FileManager.default
            .attributesOfItem(atPath: partURL.path)[.size] as? UInt64) ?? 0)
        var effectiveResumeData = resumeData
        if isResume && partSize > 0 {
            request.setValue("bytes=\(partSize)-", forHTTPHeaderField: "Range")
            effectiveResumeData = nil
        }
        let transferID = try await transport.start(request: request, resumeData: effectiveResumeData,
                                                   destination: partURL,
                                                   taskKey: Self.taskKey(jobID: job.id,
                                                                         fileIndex: fileIndex))
        transferToFile[transferID] = (job.id, fileIndex)
        runningCount += 1
        diagnostics.record("started \(source.relativePath)", jobID: job.id, fileIndex: fileIndex)
    }

    private func pauseForPolicy(jobID: UUID, reason: PauseReason) async throws {
        guard !tombstonedJobs.contains(jobID) else { return }
        guard var job = try await store.job(id: jobID) else { return }
        // Queued files stay queued so the policy auto-lifts on the next pump
        // without a manual resume; only in-flight files are paused.
        var pausedAny = false
        for index in job.files.indices {
            let current = DownloadState(pausedPersisted: job.files[index])
            if case .downloading = current {
                apply(DownloadReducer.reduce(current, .pause(resumeDataAvailable: job.files[index].hasResumeData)),
                      to: &job.files[index])
                job.files[index].pauseReason = reason.rawValue
                pausedAny = true
                if let (transferID, _) = runningTransfers(for: jobID, fileIndex: index).first {
                    transferToFile.removeValue(forKey: transferID)
                    intentionallyStopped.insert(transferID)
                    runningCount = max(0, runningCount - 1)
                    if let data = await transport.pause(transferID) {
                        try saveResumeData(data, jobID: jobID, fileIndex: index)
                        job.files[index].hasResumeData = true
                    }
                }
            }
        }
        if pausedAny, !tombstonedJobs.contains(jobID) { _ = try await store.upsert(job) }
        // Record diagnostics even when nothing was in flight: a queued-only
        // job blocked by policy must still explain why it is waiting. The
        // pump is event-driven, so repeat records are bounded.
        switch reason {
        case .unplugged:
            diagnostics.record("paused: waiting for charger (only-while-charging policy)", jobID: jobID)
        case .networkPolicy:
            diagnostics.record("paused: waiting for Wi-Fi (Wi-Fi-only policy)", jobID: jobID)
        case .user:
            break
        }
    }

    // MARK: - Event handling

    private var pumpStarted = false

    private func startEventPump() async {
        guard !pumpStarted else { return }
        pumpStarted = true
        let stream = transport.events
        eventTask = Task { [weak self] in
            for await (transferID, event) in stream {
                await self?.handleEvent(transferID: transferID, event: event)
            }
        }
    }

    private func handleEvent(transferID: DownloadTransport.TransferID, event: DownloadTransportEvent) async {
        // A transfer the manager itself paused/cancelled still delivers its
        // cancellation callback (NSURLErrorCancelled, possibly with resume
        // data) and sometimes a trailing progress event. None of these are
        // failures: consume and ignore them.
        if intentionallyStopped.contains(transferID) {
            switch event {
            case .finished, .failed:
                intentionallyStopped.remove(transferID)
            case .progress:
                break  // keep the marker until the terminal event arrives
            }
            return
        }
        guard let (jobID, fileIndex) = transferToFile[transferID] else { return }
        // The job was cancelled while this event was in flight: never touch
        // the store for it — an upsert here would resurrect a removed job.
        if tombstonedJobs.contains(jobID) {
            if case .progress = event {} else {
                transferToFile.removeValue(forKey: transferID)
            }
            return
        }
        do {
            guard var job = try await store.job(id: jobID), fileIndex < job.files.count else {
                // Job vanished (cancelled) while we awaited the store: drop
                // the mapping so no later event walks this path again.
                transferToFile.removeValue(forKey: transferID)
                return
            }
            var file = job.files[fileIndex]
            switch event {
            case .progress(let received, _):
                file.bytesReceived = received
                let current = DownloadState(pausedPersisted: file)
                // A trailing progress event can arrive after the transport's
                // .finished/.failed was already handled (URLSession delivers
                // a final didWriteData before didFinishDownloadingTo; mocks
                // and background sessions can interleave them). Progress only
                // makes sense while downloading — in .verifying it would be
                // an illegal reducer transition that silently reverts the
                // state before upsert, losing the verification step.
                guard case .downloading = current else { return }
                let progress = file.expectedSize > 0 ? Double(received) / Double(file.expectedSize) : 0
                apply(DownloadReducer.reduce(current, .progress(min(1, progress))), to: &file)
                job.files[fileIndex] = file
                if !tombstonedJobs.contains(jobID) {
                    _ = try await store.upsert(job)
                }
            case .finished(let appending):
                transferToFile.removeValue(forKey: transferID)
                runningCount = max(0, runningCount - 1)
                try await finishFile(job: &job, fileIndex: fileIndex, appending: appending)
                schedule()
            case .failed(let error, let resumeData):
                transferToFile.removeValue(forKey: transferID)
                runningCount = max(0, runningCount - 1)
                // Cancellation of a transfer the manager did NOT stop itself
                // (system-suspended background task, session invalidation) is
                // not an error and is never retried: keep the resume data and
                // pause, so the next pump/resume continues from the bytes on
                // disk instead of bouncing the file with backoff restarts.
                if Self.isCancellation(error) {
                    if let resumeData {
                        try saveResumeData(resumeData, jobID: jobID, fileIndex: fileIndex)
                        file.hasResumeData = true
                    }
                    let current = DownloadState(pausedPersisted: file)
                    apply(DownloadReducer.reduce(current,
                        .pause(resumeDataAvailable: file.hasResumeData)), to: &file)
                    job.files[fileIndex] = file
                    if !tombstonedJobs.contains(jobID) {
                        _ = try await store.upsert(job)
                    }
                    diagnostics.record("transfer cancelled by system; paused \(file.relativePath)",
                                       jobID: jobID, fileIndex: fileIndex)
                    schedule()
                    return
                }
                if let resumeData {
                    try saveResumeData(resumeData, jobID: jobID, fileIndex: fileIndex)
                    file.hasResumeData = true
                }
                await handleFailure(job: &job, fileIndex: fileIndex, error: error)
                schedule()
            }
        } catch {
            Log.error(.download, "event handling failed: \(error.localizedDescription)")
        }
    }

    private func finishFile(job: inout DownloadJob, fileIndex: Int, appending: Bool) async throws {
        var file = job.files[fileIndex]
        let current = DownloadState(pausedPersisted: file)
        apply(DownloadReducer.reduce(current, .verify), to: &file)
        job.files[fileIndex] = file
        if !tombstonedJobs.contains(job.id) {
            _ = try await store.upsert(job)
        }

        let partURL = try layout.partialFileURL(jobID: job.id, relativePath: file.relativePath)

        // Size check always runs. A resumed transfer reported only the
        // suffix bytes as progress, so reconcile bytesReceived with the
        // on-disk size before comparing against expectedSize.
        let size = Int64((try FileManager.default.attributesOfItem(atPath: partURL.path)[.size] as? UInt64) ?? 0)
        if appending { file.bytesReceived = size }
        if size != file.expectedSize {
            try? FileManager.default.removeItem(at: partURL)
            await failFile(job: &job, fileIndex: fileIndex,
                           error: .corrupted("size mismatch: got \(size), expected \(file.expectedSize)"))
            return
        }
        // SHA-256 check when a digest is known.
        if let expected = file.sha256 {
            let digest = try Self.sha256Hex(of: partURL)
            if digest != expected.lowercased() {
                try? FileManager.default.removeItem(at: partURL)
                await failFile(job: &job, fileIndex: fileIndex,
                               error: .corrupted("sha256 mismatch: got \(digest)"))
                return
            }
        }

        let verifying = DownloadState(pausedPersisted: file)
        apply(DownloadReducer.reduce(verifying, .complete), to: &file)
        _ = try layout.install(jobID: job.id, relativePath: file.relativePath,
                               repoID: job.modelRepoID, revision: job.revision)
        file.bytesReceived = file.expectedSize
        job.files[fileIndex] = file
        if tombstonedJobs.contains(job.id) { return }
        _ = try await store.upsert(job)
        diagnostics.record("completed \(file.relativePath) (\(file.expectedSize) bytes)",
                           jobID: job.id, fileIndex: fileIndex)
        // Re-fetch: another file may have completed while we were verifying.
        let latest = try await store.job(id: job.id)
        if latest?.files.allSatisfy({ $0.state == .completed }) == true {
            try writeMetadata(for: job)
            layout.removeJobArtifacts(jobID: job.id)
        }
    }

    private enum FileFailure {
        case corrupted(String)
    }

    private func failFile(job: inout DownloadJob, fileIndex: Int, error: FileFailure) async {
        var file = job.files[fileIndex]
        let locallyError: LocallyError
        switch error {
        case .corrupted(let detail):
            locallyError = .downloadFailed(
                userMessage: "The downloaded file was corrupted and has been deleted. Retry to fetch it again.",
                technicalDetail: detail)
        }
        let current = DownloadState(pausedPersisted: file)
        apply(DownloadReducer.reduce(current, .fail(locallyError)), to: &file)
        file.failureDetail = locallyError.technicalDetail
        file.failureUserMessage = locallyError.userMessage
        job.files[fileIndex] = file
        if !tombstonedJobs.contains(job.id) {
            _ = try? await store.upsert(job)
        }
        diagnostics.record("failed \(file.relativePath): \(locallyError.technicalDetail)",
                           jobID: job.id, fileIndex: fileIndex)
    }

    private func handleFailure(job: inout DownloadJob, fileIndex: Int, error: Error) async {
        var file = job.files[fileIndex]
        let locallyError = Self.mapError(error)
        let isAuth = Self.isAuthFailure(error)
        let current = DownloadState(pausedPersisted: file)
        if !isAuth, file.attempts < Self.maxAutomaticRetries, Self.isNetworkish(error) {
            // Automatic retry with exponential backoff: 1s, 2s, 4s.
            apply(DownloadReducer.reduce(current, .fail(locallyError)), to: &file)
            file.failureDetail = locallyError.technicalDetail
            file.failureUserMessage = locallyError.userMessage
            job.files[fileIndex] = file
            if !tombstonedJobs.contains(job.id) {
                _ = try? await store.upsert(job)
            }
            diagnostics.record("retrying \(file.relativePath) after error: \(locallyError.technicalDetail)",
                               jobID: job.id, fileIndex: fileIndex)
            let delay = pow(2.0, Double(file.attempts))
            await clock.sleep(delay)
            try? await retry(jobID: job.id)
        } else {
            apply(DownloadReducer.reduce(current, .fail(locallyError)), to: &file)
            file.failureDetail = locallyError.technicalDetail
            file.failureUserMessage = locallyError.userMessage
            job.files[fileIndex] = file
            if !tombstonedJobs.contains(job.id) {
                _ = try? await store.upsert(job)
            }
            diagnostics.record("failed \(file.relativePath): \(locallyError.technicalDetail)",
                               jobID: job.id, fileIndex: fileIndex)
        }
    }

    // MARK: - Helpers

    private func runningTransfers(for jobID: UUID, fileIndex: Int) -> [(DownloadTransport.TransferID, Void)] {
        transferToFile.filter { $0.value == (jobID, fileIndex) }.map { ($0.key, ()) }
    }

    private func apply(_ next: DownloadState, to file: inout DownloadFileTask) {
        switch next {
        case .queued: file.state = .queued
        case .preparing: file.state = .preparing
        case .downloading(let p): file.state = .downloading; file.progress = p
        case .paused(let hasResume): file.state = .paused; file.hasResumeData = file.hasResumeData || hasResume
        case .verifying: file.state = .verifying
        case .completed: file.state = .completed; file.progress = 1
        case .failed(let e): file.state = .failed; file.failureDetail = e.technicalDetail
        case .cancelled: file.state = .cancelled
        }
    }

    private func saveResumeData(_ data: Data, jobID: UUID, fileIndex: Int) throws {
        let url = layout.resumeDataURL(jobID: jobID, fileIndex: fileIndex)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func loadResumeData(jobID: UUID, fileIndex: Int) -> Data? {
        try? Data(contentsOf: layout.resumeDataURL(jobID: jobID, fileIndex: fileIndex))
    }

    private func writeMetadata(for job: DownloadJob) throws {
        var files: [String: Int64] = [:]
        for file in job.files { files[file.relativePath] = file.expectedSize }
        let metadata = InstalledModelMetadata(repoID: job.modelRepoID, revision: job.revision, files: files)
        let url = layout.metadataURL(repoID: job.modelRepoID, revision: job.revision)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(metadata).write(to: url, options: .atomic)
    }

    /// Recent lifecycle/policy/error events for the Diagnostics screen.
    /// Technical details only — never tokens or headers.
    public nonisolated func recentDiagnostics(limit: Int = 50) -> [DownloadDiagnosticsEvent] {
        diagnostics.recent(limit: limit)
    }

    deinit { eventTask?.cancel() }
}
