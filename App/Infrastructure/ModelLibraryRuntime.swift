import Foundation
import LocallyCore
import LocallyHF
import LocallyStorage

/// Environment-injectable holder so SwiftUI views reach the shared
/// registry and install service without singletons at the call site.
@Observable
final class ModelLibraryHolder {
    var registry: ModelRegistry?
    var installService: ModelInstallService?

    init(registry: ModelRegistry? = nil, installService: ModelInstallService? = nil) {
        self.registry = registry
        self.installService = installService
    }
}

/// Starts the model library at launch: loads the registry from Application
/// Support, reconciles records against the filesystem, and builds the
/// install service on top of the shared DownloadManager.
@MainActor
final class ModelLibraryRuntime {
    static let shared = ModelLibraryRuntime()

    let holder = ModelLibraryHolder()
    /// Orphan folders found at launch; shown in the library UI, never
    /// deleted silently.
    var lastReconcileReport: ModelRegistry.ReconcileReport?

    private init() {}

    /// Idempotent. Safe to call after DownloadRuntime.start.
    func start() {
        guard holder.registry == nil else { return }
        let registry = ModelRegistry.applicationSupport()
        holder.registry = registry
        Task {
            try? await registry.load()
            let report = try? await registry.reconcile()
            await MainActor.run { [weak self] in self?.lastReconcileReport = report }
        }
        guard let manager = DownloadRuntime.shared.holder.manager else { return }
        holder.installService = ModelInstallService(
            downloadManager: manager,
            registry: registry,
            authHeaderProvider: {
                // Token read at request time; never stored on this object.
                #if canImport(Security)
                return try KeychainTokenStore().readToken()
                #else
                return nil
                #endif
            })
    }
}
