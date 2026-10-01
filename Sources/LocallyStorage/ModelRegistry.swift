import Foundation
import LocallyCore

/// Persistent registry of installed models. Records live in
/// `<root>/registry.json` (atomic writes); model payloads live under the
/// FilesystemLayout model tree. Mutations are serialized by the actor;
/// read-only queries are nonisolated so callers (including tests and
/// SwiftUI views) can read without awaiting.
public actor ModelRegistry {
    public struct StorageSummary: Sendable, Hashable {
        public var perModel: [String: Int64]
        public var totalModelBytes: Int64
        public var downloadCacheBytes: Int64
    }

    public struct ReconcileReport: Sendable, Hashable {
        /// Repo ids whose revision folder exists but is not registered.
        public var orphanDirectories: [String]
        /// Registered ids whose on-disk files are missing (flagged, kept).
        public var missingFileIDs: [String]
    }

    public enum RegistryError: Error, Sendable, Hashable {
        case notFound(String)
        case modelLoaded(String)
    }

    private let root: URL
    private let layout: FilesystemLayout
    private let loadedChecker: any ModelLoadedChecking
    private let now: @Sendable () -> Date
    private let state: LockedState<[String: InstalledModel]>

    public init(root: URL,
                loadedChecker: any ModelLoadedChecking = NoModelLoadedChecker(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root
        self.layout = FilesystemLayout(root: root)
        self.loadedChecker = loadedChecker
        self.now = now
        self.state = LockedState([:])
    }

    /// Default registry under Application Support, for the app layer.
    public static func applicationSupport(
        loadedChecker: any ModelLoadedChecking = NoModelLoadedChecker()
    ) -> ModelRegistry {
        ModelRegistry(root: FilesystemLayout.applicationSupport().root,
                      loadedChecker: loadedChecker)
    }

    private var registryURL: URL { root.appendingPathComponent("registry.json") }

    // MARK: - Persistence

    /// Load records from disk. A missing file means an empty registry.
    public func load() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: registryURL.path) else {
            state.withLock { $0 = [:] }
            return
        }
        let data = try Data(contentsOf: registryURL)
        let decoded = try JSONDecoder().decode([InstalledModel].self, from: data)
        state.withLock { $0 = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) }) }
    }

    private func persist() throws {
        let snapshot = state.withLock { $0 }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot.values.sorted { $0.id < $1.id })
        // Atomic: rename over the existing file, never a partial write.
        try data.write(to: registryURL, options: .atomic)
    }

    // MARK: - Queries (nonisolated reads of the mutex-guarded snapshot)

    public nonisolated func list() -> [InstalledModel] {
        state.withLock { models in
            models.values.sorted {
                ($0.lastUsedAt ?? $0.installedAt) > ($1.lastUsedAt ?? $1.installedAt)
            }
        }
    }

    public nonisolated func get(id: String) -> InstalledModel? {
        state.withLock { $0[id] }
    }

    public nonisolated func recentModels(limit: Int = 5) -> [InstalledModel] {
        state.withLock { models in
            models.values.filter { $0.lastUsedAt != nil }
                .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
                .prefix(limit).map { $0 }
        }
    }

    // MARK: - Mutation

    /// Register a freshly installed model (or replace the same id on reinstall).
    public func register(_ model: InstalledModel) throws {
        var copy = model
        copy.sizeOnDisk = Self.directorySize(layout.modelDirectory(repoID: model.repoID,
                                                                   revision: model.revision))
        state.withLock { $0[model.id] = copy }
        try writePerModelMetadata(copy)
        try persist()
    }

    public func markUsed(id: String) throws {
        try state.withLock { models in
            guard var model = models[id] else { throw RegistryError.notFound(id) }
            model.lastUsedAt = now()
            models[id] = model
        }
        try persist()
    }

    /// Apply user overrides. Context is clamped to the descriptor's maximum.
    public func updateSettings(id: String, runtime: RuntimeKind?? = nil,
                               context: Int?? = nil) throws {
        try state.withLock { models in
            guard var model = models[id] else { throw RegistryError.notFound(id) }
            if let runtime {
                model.runtimeOverride = runtime
                model.runtime = runtime ?? model.descriptor.supportedRuntimes.first
            }
            if let context {
                if let value = context, let maxContext = model.descriptor.contextLength {
                    model.contextOverride = min(max(1, value), maxContext)
                } else {
                    model.contextOverride = context
                }
            }
            models[id] = model
        }
        try persist()
    }

    public func recordBenchmark(id: String, sample: InferenceMetadata) throws {
        try state.withLock { models in
            guard var model = models[id] else { throw RegistryError.notFound(id) }
            model.benchmarks.append(sample)
            models[id] = model
        }
        try persist()
    }

    /// Delete the record and its files. Refuses while a runtime has the
    /// model loaded.
    public func delete(id: String) async throws {
        guard let model = get(id: id) else { throw RegistryError.notFound(id) }
        if await loadedChecker.isModelLoaded(repoID: model.repoID, revision: model.revision) {
            throw RegistryError.modelLoaded(id)
        }
        let directory = layout.modelDirectory(repoID: model.repoID, revision: model.revision)
        try? FileManager.default.removeItem(at: directory)
        let parent = directory.deletingLastPathComponent()
        // Remove the org_name folder when no revisions remain.
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: parent.path),
           contents.isEmpty {
            try? FileManager.default.removeItem(at: parent)
        }
        state.withLock { _ = $0.removeValue(forKey: id) }
        try persist()
    }

    // MARK: - Storage accounting

    public nonisolated func storageSummary() -> StorageSummary {
        let snapshot = state.withLock { $0 }
        var perModel: [String: Int64] = [:]
        for model in snapshot.values {
            perModel[model.id] = Self.directorySize(layout.modelDirectory(repoID: model.repoID,
                                                                          revision: model.revision))
        }
        let total = perModel.values.reduce(0, +)
        return StorageSummary(perModel: perModel,
                              totalModelBytes: total,
                              downloadCacheBytes: Self.directorySize(layout.downloadsRoot))
    }

    /// Recompute sizeOnDisk from the filesystem (call after deletes/cancelled jobs).
    public func refreshSizes() throws {
        let ids = state.withLock { Array($0.keys) }
        for id in ids {
            state.withLock { models in
                guard var model = models[id] else { return }
                model.sizeOnDisk = Self.directorySize(layout.modelDirectory(repoID: model.repoID,
                                                                            revision: model.revision))
                models[id] = model
            }
        }
        try persist()
    }

    // MARK: - Reconcile

    /// Compare records with the filesystem. Missing files are flagged on the
    /// record (surfaced honestly in the UI), never silently deleted. Orphan
    /// folders are reported for the caller to show; removing them is an
    /// explicit user action, not a launch-time side effect.
    @discardableResult
    public func reconcile() throws -> ReconcileReport {
        let fm = FileManager.default
        var orphans: [String] = []
        var missing: [String] = []

        let registeredPaths = state.withLock { models in
            Set(models.values.map {
                layout.modelDirectory(repoID: $0.repoID, revision: $0.revision).standardizedFileURL.path
            })
        }
        let modelsRoot = layout.modelsRoot
        if let orgDirs = try? fm.contentsOfDirectory(atPath: modelsRoot.path) {
            for orgDir in orgDirs {
                let orgURL = modelsRoot.appendingPathComponent(orgDir, isDirectory: true)
                guard let revisions = try? fm.contentsOfDirectory(atPath: orgURL.path) else { continue }
                for revision in revisions {
                    let revisionURL = orgURL.appendingPathComponent(revision, isDirectory: true)
                    if !registeredPaths.contains(revisionURL.standardizedFileURL.path) {
                        orphans.append("\(orgDir)/\(revision)")
                    }
                }
            }
        }

        var changed = false
        state.withLock { models in
            for (id, var model) in models {
                let directory = layout.modelDirectory(repoID: model.repoID, revision: model.revision)
                let exists = fm.fileExists(atPath: directory.path)
                if !exists { missing.append(id) }
                if !exists && !model.hasMissingFiles {
                    model.hasMissingFiles = true
                    models[id] = model
                    changed = true
                } else if exists && model.hasMissingFiles {
                    model.hasMissingFiles = false
                    models[id] = model
                    changed = true
                }
            }
        }
        if changed { try persist() }
        return ReconcileReport(orphanDirectories: orphans.sorted(), missingFileIDs: missing.sorted())
    }

    // MARK: - Helpers

    /// metadata.json inside the model folder: what the download layer wrote,
    /// refreshed with registry truth (so a folder alone tells its story).
    private func writePerModelMetadata(_ model: InstalledModel) throws {
        let url = layout.metadataURL(repoID: model.repoID, revision: model.revision)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var files: [String: Int64] = [:]
        for file in model.descriptor.requiredFiles { files[file.path] = file.size }
        let metadata = InstalledModelMetadata(repoID: model.repoID, revision: model.revision,
                                              files: files, installedAt: model.installedAt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(metadata).write(to: url, options: .atomic)
    }

    /// Recursive size of a directory in bytes; 0 when it does not exist.
    public nonisolated static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                                             options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            // Skip directories: their sizes are filesystem-dependent metadata.
            guard values?.isDirectory != true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }
}
