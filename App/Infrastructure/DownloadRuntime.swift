import Foundation
import UIKit
import LocallyStorage

/// App-delegate glue for the background URLSession: constructs the shared
/// DownloadManager (background transport on iOS) and routes
/// `application(_:handleEventsForBackgroundURLSession:)` to it.
final class DownloadRuntime: NSObject {
    static let shared = DownloadRuntime()

    let holder = DownloadManagerHolder()
    private(set) var transport: URLSessionBackgroundTransport?

    private override init() {
        super.init()
    }

    /// Called once at app launch. Recreating the background session with the
    /// same identifier reattaches any transfers iOS kept alive across a
    /// relaunch; `taskDescription` ("<jobID>|<fileIndex>") maps them back.
    @MainActor
    func start(authHeaderProvider: @escaping @Sendable (URL) -> String?) {
        guard holder.manager == nil else { return }
        let layout = FilesystemLayout.applicationSupport()
        let transport = URLSessionBackgroundTransport()
        self.transport = transport
        let manager = DownloadManager(
            store: DownloadStore(
                directory: layout.downloadsRoot.appendingPathComponent("store", isDirectory: true)),
            layout: layout,
            transport: transport,
            authHeaderProvider: authHeaderProvider)
        holder.manager = manager
        Task {
            try? await manager.restore()
        }
    }

    /// App delegate hook: forward relaunch events for our session identifier.
    func handleEventsForBackgroundURLSession(_ identifier: String,
                                             completionHandler: @escaping () -> Void) {
        guard identifier == URLSessionBackgroundTransport.sessionIdentifier else {
            completionHandler()
            return
        }
        transport?.handleEvents(completionHandler: completionHandler)
            ?? BackgroundSessionCoordinator.shared.registerCompletionHandler(completionHandler,
                                                                             for: identifier)
    }
}
