import Foundation
import LocallyCore
import LocallyStorage

/// View model wrapping DownloadManager for the Downloads screen.
/// Polls the store on a slow cadence and computes per-job speed from real
/// progress samples. Actions forward to the manager; failures surface as an
/// inline banner via ErrorPresentation instead of being swallowed, and each
/// tap applies an optimistic local state so the UI reacts immediately.
@Observable
@MainActor
final class DownloadsViewModel {
    struct Row: Identifiable, Sendable {
        var id: UUID
        var repoID: String
        var revision: String
        var state: DownloadFileTask.PersistedState
        var bytesDownloaded: Int64
        var totalBytes: Int64
        var bytesPerSecond: Double?
        var failureMessage: String?
    }

    /// One user action per job; the row's buttons are disabled while set.
    enum PendingAction: Sendable {
        case pausing, resuming, cancelling, retrying
    }

    private(set) var rows: [Row] = []
    /// Inline error banner text (ErrorPresentation user message). Set by any
    /// failed action; cleared on the next successful action or by the user.
    var actionError: String?
    /// Optimistic overlays: taps flip the row's state instantly and disable
    /// its buttons until the manager call settles and the poll catches up.
    private(set) var pending: [UUID: PendingAction] = [:]
    var wifiOnly = DownloadPolicySettings.load().wifiOnly {
        didSet { DownloadPolicySettings.save(wifiOnly: wifiOnly, chargingOnly: chargingOnly) }
    }
    var chargingOnly = DownloadPolicySettings.load().chargingOnly {
        didSet { DownloadPolicySettings.save(wifiOnly: wifiOnly, chargingOnly: chargingOnly) }
    }
    var concurrency: Int = 2 {
        didSet { Task { await manager?.setConcurrentFileLimit(concurrency) } }
    }

    private var manager: DownloadManager?
    private var pollTask: Task<Void, Never>?
    private var samples: [UUID: (date: Date, bytes: Int64)] = [:]
    private var enqueuedPolicies: [UUID: DownloadPolicy] = [:]

    func attach(manager: DownloadManager) {
        guard self.manager == nil else { return }
        self.manager = manager
        startPolling()
    }

    func detach() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func refresh() async {
        guard let manager else { return }
        guard let jobs = try? await manager.jobs() else { return }
        let now = Date()
        let liveIDs = Set(jobs.map(\.id))
        // A pending overlay clears once the store reflects the target state
        // (or the row vanished after a cancel).
        for (id, action) in pending {
            guard let job = jobs.first(where: { $0.id == id }) else {
                pending.removeValue(forKey: id)
                samples.removeValue(forKey: id)
                continue
            }
            let settled: Bool
            switch action {
            case .pausing: settled = job.aggregateState == .paused || job.isFinished
            case .resuming: settled = job.aggregateState == .downloading || job.isFinished
            case .retrying: settled = job.aggregateState == .downloading || job.aggregateState == .queued
            case .cancelling: settled = false  // clears when the row vanishes
            }
            if settled { pending.removeValue(forKey: id) }
        }
        samples = samples.filter { liveIDs.contains($0.key) }
        rows = jobs.sorted { $0.createdAt > $1.createdAt }.map { job in
            var speed: Double?
            let bytes = job.bytesDownloaded
            if let prev = samples[job.id] {
                let dt = now.timeIntervalSince(prev.date)
                let db = Double(bytes - prev.bytes)
                if dt > 0.1 && db >= 0 { speed = db / dt }
            }
            samples[job.id] = (now, bytes)
            enqueuedPolicies[job.id] = job.policy
            var state = job.aggregateState
            // Optimistic overlay until the manager round-trip lands.
            if let action = pending[job.id] {
                switch action {
                case .pausing: state = .paused
                case .resuming, .retrying: state = .queued
                case .cancelling: break
                }
            }
            return Row(id: job.id, repoID: job.modelRepoID, revision: job.revision,
                       state: state, bytesDownloaded: bytes,
                       totalBytes: job.totalBytes,
                       bytesPerSecond: job.aggregateState == .downloading ? speed : nil,
                       failureMessage: job.files.first(where: { $0.state == .failed })
                           .map { $0.failureUserMessage ?? $0.failureDetail ?? "" })
        }
    }

    func pause(_ id: UUID) {
        perform(id, action: .pausing) { try await $0.pause(jobID: id) }
    }

    func resume(_ id: UUID) {
        perform(id, action: .resuming) { try await $0.resume(jobID: id) }
    }

    func cancel(_ id: UUID) {
        samples.removeValue(forKey: id)
        perform(id, action: .cancelling) { try await $0.cancel(jobID: id) }
    }

    func retry(_ id: UUID) {
        perform(id, action: .retrying) { try await $0.retry(jobID: id) }
    }

    func dismissError() {
        actionError = nil
    }

    /// Runs one manager action with an optimistic overlay, in-flight
    /// disabling, and error surfacing. Failures clear the overlay so the
    /// poll restores the true state and the banner explains what happened.
    private func perform(_ id: UUID, action: PendingAction,
                         _ call: @escaping (DownloadManager) async throws -> Void) {
        guard let manager, pending[id] == nil else { return }
        pending[id] = action
        applyOptimistic(action, to: id)
        Task { [weak self] in
            do {
                try await call(manager)
                await self?.refresh()
            } catch {
                await MainActor.run {
                    self?.pending.removeValue(forKey: id)
                    self?.actionError = ErrorPresentation.userMessage(for: error)
                }
                await self?.refresh()
            }
        }
    }

    /// Immediate local state flip so the tap feels responsive; the next poll
    /// reconciles with the store.
    private func applyOptimistic(_ action: PendingAction, to id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        switch action {
        case .pausing: rows[index].state = .paused
        case .resuming, .retrying: rows[index].state = .queued
        case .cancelling: break  // row disappears on the next poll
        }
    }

    func pendingAction(for id: UUID) -> PendingAction? {
        pending[id]
    }

    /// Policy toggles apply to future jobs; already-enqueued jobs keep the
    /// policy they started with (visible in the row's state).
    var currentPolicy: DownloadPolicy {
        DownloadPolicySettings.policy
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1000 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return String(format: unit == 0 ? "%.0f %@" : "%.1f %@", value, units[unit])
    }
}

/// Persists the Downloads-tab policy toggles so Add-Model installs pick
/// them up; without this the toggles changed nothing (the toggles were the
/// only policy source and were never read at enqueue time).
enum DownloadPolicySettings {
    private static let wifiKey = "downloads.wifiOnly"
    private static let chargingKey = "downloads.chargingOnly"

    static func load(defaults: UserDefaults = .standard)
        -> (wifiOnly: Bool, chargingOnly: Bool) {
        (defaults.bool(forKey: wifiKey), defaults.bool(forKey: chargingKey))
    }

    static func save(wifiOnly: Bool, chargingOnly: Bool,
                     defaults: UserDefaults = .standard) {
        defaults.set(wifiOnly, forKey: wifiKey)
        defaults.set(chargingOnly, forKey: chargingKey)
    }

    static var policy: DownloadPolicy {
        let (wifiOnly, chargingOnly) = load()
        return DownloadPolicy(allowsCellular: !wifiOnly, onlyWhileCharging: chargingOnly)
    }
}
