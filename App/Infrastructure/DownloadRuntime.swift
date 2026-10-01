import Foundation
import UIKit
import LocallyStorage

/// App-delegate glue for the background URLSession: constructs the shared
/// DownloadManager (background transport on iOS) and routes
/// `application(_:handleEventsForBackgroundURLSession:)` to it.
/// All entry points are MainActor (app delegate / app init), so isolate the
/// whole type to MainActor to make `shared` concurrency-safe.
@MainActor
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
    /// The stored completion handler is wrapped so it is always invoked on
    /// the main thread — UIKit documents the handler as main-thread, and the
    /// URLSession delegate callback that releases it arrives on a delegate
    /// queue.
    func handleEventsForBackgroundURLSession(_ identifier: String,
                                             completionHandler: @escaping () -> Void) {
        // The UIApplicationDelegate signature is `() -> Void` (non-Sendable),
        // but the coordinator's registry requires @Sendable. Box the handler:
        // it is only ever invoked once, on the main thread.
        let boxed = CompletionHandlerBox(completionHandler)
        let mainThreadHandler: @Sendable () -> Void = {
            DispatchQueue.main.async { boxed.invoke() }
        }
        guard identifier == URLSessionBackgroundTransport.sessionIdentifier else {
            completionHandler()
            return
        }
        // The transport was recreated at launch before the UI loaded, so any
        // transfers iOS kept alive are already reattaching; `restore()` (in
        // start) replays the persisted job states the Downloads tab shows.
        transport?.handleEvents(completionHandler: mainThreadHandler)
            ?? BackgroundSessionCoordinator.shared.registerCompletionHandler(mainThreadHandler,
                                                                             for: identifier)
    }
}

/// @unchecked Sendable wrapper for UIKit's non-Sendable completion handler;
/// the handler is invoked at most once and only on the main thread.
private final class CompletionHandlerBox: @unchecked Sendable {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    func invoke() { handler() }
}
