import Foundation
import LocallyCore
import LocallyStorage

/// View model wrapping DownloadManager for the Downloads screen.
/// Polls the store on a slow cadence and computes per-job speed from real
/// progress samples; all actions forward to the manager.
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

    private(set) var rows: [Row] = []
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
            return Row(id: job.id, repoID: job.modelRepoID, revision: job.revision,
                       state: job.aggregateState, bytesDownloaded: bytes,
                       totalBytes: job.totalBytes,
                       bytesPerSecond: job.aggregateState == .downloading ? speed : nil,
                       failureMessage: job.files.first(where: { $0.state == .failed })
                           .map { $0.failureUserMessage ?? $0.failureDetail ?? "" })
        }
    }

    func pause(_ id: UUID) {
        Task { try? await manager?.pause(jobID: id) }
    }

    func resume(_ id: UUID) {
        Task { try? await manager?.resume(jobID: id) }
    }

    func cancel(_ id: UUID) {
        samples.removeValue(forKey: id)
        Task { try? await manager?.cancel(jobID: id) }
    }

    func retry(_ id: UUID) {
        Task { try? await manager?.retry(jobID: id) }
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
