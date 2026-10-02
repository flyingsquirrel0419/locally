import Foundation
import UIKit
#if canImport(Network)
import Network
#endif
import LocallyCore
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
    #if canImport(Network)
    /// Latest published path; nil until the monitor's first update.
    /// Unknown must read as "usable" so a download never stalls waiting for
    /// a snapshot that may not arrive before the user taps Download.
    private let pathMonitor = NWPathMonitor()
    private let pathState = LockedState<Bool?>(nil)
    #endif

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
            authHeaderProvider: authHeaderProvider,
            power: Self.makePowerProvider(),
            network: makeNetworkProvider())
        holder.manager = manager
        Task {
            try? await manager.restore()
        }
    }

    /// UIDevice battery state: charging or full counts as charging; the
    /// unknown state (battery monitoring off, simulator) must not block.
    /// `UIDevice.current` is MainActor-isolated, while the provider's
    /// @Sendable closure runs on the manager's actor — so the state is
    /// snapshotted into a LockedState here (MainActor) and kept fresh by
    /// batteryStateDidChangeNotification.
    @MainActor
    private static func makePowerProvider() -> PowerStateProvider {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let snapshot = LockedState<Bool?>(Self.isChargingNow())
        let observer = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            // queue: .main guarantees the main thread; the compiler cannot
            // see it, so assert the isolation explicitly.
            MainActor.assumeIsolated {
                snapshot.withLock { $0 = Self.isChargingNow() }
            }
        }
        // The observer must live as long as the provider; tie it to the
        // snapshot's lifetime via a retain box captured by the closure.
        let keepAlive = ObserverBox(observer)
        return PowerStateProvider {
            _ = keepAlive
            return snapshot.withLock { $0 ?? true }
        }
    }

    @MainActor
    private static func isChargingNow() -> Bool {
        switch UIDevice.current.batteryState {
        case .charging, .full: return true
        case .unplugged: return false
        case .unknown: return true
        @unknown default: return true
        }
    }

    /// NWPathMonitor snapshot: nil (no snapshot yet) → usable; otherwise the
    /// path must be satisfied and not cellular/hotspot.
    private func makeNetworkProvider() -> NetworkPathProvider {
        #if canImport(Network)
        pathMonitor.pathUpdateHandler = { [pathState] path in
            let usable = path.status == .satisfied
                && !path.isExpensive
                && !path.usesInterfaceType(.cellular)
                && !path.usesInterfaceType(.other)
            pathState.withLock { $0 = usable }
        }
        pathMonitor.start(queue: DispatchQueue(label: "me.teamwicked.locally.pathmonitor"))
        let pathState = self.pathState
        return NetworkPathProvider { pathState.withLock { $0 ?? true } }
        #else
        return NetworkPathProvider()
        #endif
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

/// Keeps a NotificationCenter observer token alive as long as the box is
/// retained (captured by the power-provider closure); deregisters on deinit.
private final class ObserverBox: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}
