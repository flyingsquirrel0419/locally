import Foundation
import LocallyStorage

/// Starts the shared app-wide services at launch: runtime registry and
/// cross-tab navigation. Mirrors the ModelLibraryRuntime/DownloadRuntime
/// holder pattern.
@MainActor
final class AppRuntime {
    static let shared = AppRuntime()

    let runtimeHolder = RuntimeRegistryHolder()
    let navigation = AppNavigation()

    private init() {}

    /// Idempotent.
    func start() {
        if runtimeHolder.registry == nil {
            runtimeHolder.registry = RuntimeRegistry()
        }
    }
}
