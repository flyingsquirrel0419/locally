import Foundation
import LocallyCore
import LocallyStorage

/// View model for the Models library tab: search, sort, delete, storage
/// summary, and reconcile reporting. Reads ModelRegistry's nonisolated
/// queries on a refresh pulse; mutations go through the actor.
@Observable
@MainActor
final class ModelLibraryViewModel {
    enum Sort: String, CaseIterable {
        case recent, name, size
    }

    private(set) var models: [InstalledModel] = []
    private(set) var storage: ModelRegistry.StorageSummary?
    private(set) var reconcileReport: ModelRegistry.ReconcileReport?
    var search = ""
    var sort: Sort = .recent { didSet { applyFilter() } }
    var errorMessage: String?
    /// Model the user asked to delete; drives the confirmation dialog.
    var pendingDelete: InstalledModel?

    private var registry: ModelRegistry?
    private var availability: any RuntimeAvailabilityProvider = DescriptorRuntimeAvailability()

    var filtered: [InstalledModel] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let base = query.isEmpty ? models : models.filter {
            $0.repoID.lowercased().contains(query) || $0.descriptor.name.lowercased().contains(query)
        }
        switch sort {
        case .recent:
            return base.sorted { ($0.lastUsedAt ?? $0.installedAt) > ($1.lastUsedAt ?? $1.installedAt) }
        case .name:
            return base.sorted { $0.descriptor.name.localizedCaseInsensitiveCompare($1.descriptor.name) == .orderedAscending }
        case .size:
            return base.sorted { $0.sizeOnDisk > $1.sizeOnDisk }
        }
    }

    func attach(registry: ModelRegistry) {
        guard self.registry == nil else { return }
        self.registry = registry
        refresh()
    }

    func refresh() {
        guard let registry else { return }
        Task {
            try? await registry.load()
            let report = try? await registry.reconcile()
            await MainActor.run {
                models = registry.list()
                storage = registry.storageSummary()
                reconcileReport = report
            }
        }
    }

    private func applyFilter() {}

    func availableRuntimes(for model: InstalledModel) -> [RuntimeKind] {
        availability.availableRuntimes(for: model)
    }

    func confirmDelete(_ model: InstalledModel) {
        pendingDelete = model
    }

    func deletePending() {
        guard let model = pendingDelete, let registry else { return }
        pendingDelete = nil
        Task {
            do {
                try await registry.delete(id: model.id)
                refresh()
            } catch let error as ModelRegistry.RegistryError {
                switch error {
                case .modelLoaded:
                    errorMessage = String(localized: "models.detail.delete.loaded", table: "Models")
                case .notFound:
                    errorMessage = String(localized: "models.error.generic", table: "Models")
                }
            } catch {
                errorMessage = String(localized: "models.error.generic", table: "Models")
            }
        }
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
