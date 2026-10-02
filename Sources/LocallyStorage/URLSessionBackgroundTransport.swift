import Foundation
import LocallyCore

/// iOS background URLSession transport. One session per process lifetime,
/// recreated with the same identifier on relaunch; in-flight tasks are
/// reattached by decoding `taskDescription` ("<jobID>|<fileIndex>"), the
/// key the manager passes to `start(request:resumeData:destination:taskKey:)`.
/// This file compiles only under `#if os(iOS)`; the app wires its
/// `application(_:handleEventsForBackgroundURLSession:)` handler to
/// `BackgroundSessionCoordinator.shared.handleEvents(...)`.
#if os(iOS)
import UIKit

public final class URLSessionBackgroundTransport: NSObject, DownloadTransport,
        URLSessionDownloadDelegate, @unchecked Sendable {
    /// Identifier of the app's background session. Hosted tests must pass a
    /// unique identifier per test run: two live background sessions with the
    /// same identifier in one process are undefined behavior per Apple, and
    /// in practice the second session's tasks never deliver delegate
    /// callbacks (the exact "download starts, zero bytes arrive" stall).
    public static let sessionIdentifier = "me.teamwicked.locally.downloads"

    /// This instance's session identifier.
    public let identifier: String

    /// Identifiers of live instances in this process. A second instance with
    /// a duplicate identifier is the stall above, so DEBUG builds assert.
    private static let liveIdentifiers = LockedState<Set<String>>([])

    /// Registers `identifier` as live; in DEBUG, logs and asserts on a
    /// duplicate (a second in-process session with the same identifier).
    private static func registerLive(_ identifier: String, file: StaticString,
                                     line: UInt) {
        let duplicate = liveIdentifiers.withLock { ids -> Bool in
            if ids.contains(identifier) { return true }
            ids.insert(identifier)
            return false
        }
        #if DEBUG
        if duplicate {
            assertionFailure(
                "URLSessionBackgroundTransport: duplicate live session identifier "
                    + "\"\(identifier)\" in this process; the second background session "
                    + "receives no delegate callbacks (Apple: undefined behavior). "
                    + "Hosted tests must use a unique identifier per run.",
                file: file, line: line)
        }
        #endif
    }

    /// Releases the identifier; called from `finishTasksAndInvalidate()` /
    /// `invalidateAndCancel()` so a later instance may reuse it.
    private static func unregisterLive(_ identifier: String) {
        liveIdentifiers.withLock { _ = $0.remove(identifier) }
    }

    public typealias TransferID = Int

    private struct State {
        var nextID: TransferID = 1
        var tasksByID: [TransferID: URLSessionDownloadTask] = [:]
        var destinations: [TransferID: URL] = [:]
        /// taskDescription ("<jobID>|<fileIndex>") per transfer, set at start
        /// and recovered on relaunch; lets the manager rebind events.
        var taskKeys: [TransferID: String] = [:]
        /// True when the start resumed via Range/resume data: completion
        /// appends the received suffix to the part file instead of replacing it.
        var appending: [TransferID: Bool] = [:]
        /// Task keys of transfers reattached after a relaunch, drained by
        /// `reattachedTransfers()`.
        var pendingReattachedKeys: [String] = []
    }

    // NSLock.lock()/unlock() are unavailable from async contexts under the
    // Swift 6 SDK; LockedState.withLock is a sync entry point, so calling it
    // from async methods is permitted.
    private let state = LockedState(State())
    private var session: URLSession!

    /// DEBUG-only callback invoked with a one-line summary of every URLSession
    /// delegate callback (progress/finish/error, HTTP status, byte counts).
    /// Used by the hosted E2E tests to diagnose background-session stalls
    /// without scraping system logs. Never includes request headers or URLs.
    public var onDelegateEvent: (@Sendable (String) -> Void)?

    private func logDelegate(_ message: String) {
        #if DEBUG
        onDelegateEvent?(message)
        #endif
    }

    private let eventStream: AsyncStream<(TransferID, DownloadTransportEvent)>
    private let eventContinuation: AsyncStream<(TransferID, DownloadTransportEvent)>.Continuation

    public init(sessionIdentifier: String = URLSessionBackgroundTransport.sessionIdentifier) {
        identifier = sessionIdentifier
        var cont: AsyncStream<(TransferID, DownloadTransportEvent)>.Continuation!
        eventStream = AsyncStream { cont = $0 }
        eventContinuation = cont
        super.init()
        Self.registerLive(sessionIdentifier, file: #fileID, line: #line)
        session = Self.makeSession(identifier: sessionIdentifier, delegate: self)
        reattachExistingTasks()
    }

    /// Invalidates the session after in-flight tasks finish and releases the
    /// identifier so a later instance (e.g. the next hosted test) may reuse it.
    public func finishTasksAndInvalidate() {
        session.finishTasksAndInvalidate()
        Self.unregisterLive(identifier)
    }

    /// Cancels all tasks, invalidates the session, and releases the identifier.
    public func invalidateAndCancel() {
        session.invalidateAndCancel()
        Self.unregisterLive(identifier)
    }

    private static func makeSession(identifier: String,
                                    delegate: URLSessionDownloadDelegate) -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        // Cellular policy is enforced per-job by DownloadManager; the session
        // stays permissive so policy changes do not require session teardown.
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// Called by the app delegate when iOS relaunches the app for this session.
    /// Callers wrap UIKit's non-Sendable `() -> Void` (invoked once, on the
    /// main thread) before passing it here.
    public func handleEvents(completionHandler: @escaping @Sendable () -> Void) {
        BackgroundSessionCoordinator.shared.registerCompletionHandler(completionHandler,
                                                                      for: identifier)
    }

    /// On relaunch, map surviving tasks back to their manager-issued task
    /// keys. A task without a parseable key is orphaned: its completion could
    /// never be attributed to a job file, so it is cancelled rather than
    /// silently leaking bytes into an unknown destination.
    private func reattachExistingTasks() {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            self.state.withLock { state in
                for task in tasks {
                    guard let download = task as? URLSessionDownloadTask,
                          let key = task.taskDescription, !key.isEmpty else { continue }
                    let id = state.nextID
                    state.nextID += 1
                    state.tasksByID[id] = download
                    state.taskKeys[id] = key
                    // Reattached tasks keep their originalRequest: a Range
                    // header means the surviving transfer receives only a
                    // suffix, so completion must append, not replace.
                    state.appending[id] = download.originalRequest?
                        .value(forHTTPHeaderField: "Range") != nil
                    state.pendingReattachedKeys.append(key)
                }
            }
        }
    }

    /// Task keys of transfers that survived an app relaunch. The manager
    /// calls this from `restore()` and maps each key back to its job file.
    public func reattachedTransfers() async -> [String] {
        state.withLock { state in
            let keys = state.pendingReattachedKeys
            state.pendingReattachedKeys.removeAll()
            return keys
        }
    }

    public var events: AsyncStream<(TransferID, DownloadTransportEvent)> { eventStream }

    public func start(request: URLRequest, resumeData: Data?, destination: URL,
                      taskKey: String) async throws -> TransferID {
        // If a task for this job file survived a relaunch, adopt it instead
        // of starting a duplicate download of the same bytes.
        if let existing = state.withLock({ state -> TransferID? in
            state.taskKeys.first(where: { $0.value == taskKey })?.key
        }) {
            state.withLock {
                $0.destinations[existing] = destination
                // The manager's view wins: it knows whether this file resume
                // carries a Range header / resume data.
                $0.appending[existing] = resumeData != nil
                    || request.value(forHTTPHeaderField: "Range") != nil
            }
            return existing
        }

        let resuming = resumeData != nil || request.value(forHTTPHeaderField: "Range") != nil
        let id = state.withLock { state -> TransferID in
            let id = state.nextID
            state.nextID += 1
            state.destinations[id] = destination
            state.taskKeys[id] = taskKey
            state.appending[id] = resuming
            return id
        }

        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: request)
        }
        // taskDescription carries the correlation across process restarts.
        task.taskDescription = taskKey
        task.resume()
        state.withLock { $0.tasksByID[id] = task }
        return id
    }

    public func pause(_ id: TransferID) async -> Data? {
        await withCheckedContinuation { continuation in
            let task = state.withLock { $0.tasksByID[id] }
            guard let task else {
                continuation.resume(returning: nil)
                return
            }
            task.cancel(byProducingResumeData: { data in
                continuation.resume(returning: data)
            })
        }
    }

    public func cancel(_ id: TransferID) async {
        let task = state.withLock { state -> URLSessionDownloadTask? in
            state.destinations.removeValue(forKey: id)
            state.taskKeys.removeValue(forKey: id)
            state.appending.removeValue(forKey: id)
            return state.tasksByID.removeValue(forKey: id)
        }
        task?.cancel()
    }

    // MARK: - URLSessionDownloadDelegate

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        logDelegate("didWriteData task=\(downloadTask.taskIdentifier) "
            + "written=\(totalBytesWritten)/\(totalBytesExpectedToWrite) "
            + "state=\(downloadTask.state.rawValue)")
        guard let id = idFor(downloadTask) else { return }
        let expected = totalBytesExpectedToWrite >= 0 ? totalBytesExpectedToWrite : nil
        eventContinuation.yield((id, .progress(bytesReceived: totalBytesWritten, totalBytes: expected)))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
        logDelegate("didFinishDownloadingTo task=\(downloadTask.taskIdentifier) "
            + "status=\(status) received=\(downloadTask.countOfBytesReceived)")
        guard let id = idFor(downloadTask) else { return }
        let (destination, appending) = state.withLock { state -> (URL?, Bool) in
            state.tasksByID.removeValue(forKey: id)
            state.taskKeys.removeValue(forKey: id)
            return (state.destinations.removeValue(forKey: id),
                    state.appending.removeValue(forKey: id) ?? false)
        }
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
            eventContinuation.yield((id, .failed(error: HTTPStatusError(statusCode: http.statusCode),
                                                 resumeData: nil)))
            return
        }
        // Persist the temp file before URLSession deletes it. A resuming
        // transfer (Range header or resume data) received only the suffix:
        // append it to the part file's existing prefix. A full 200 response
        // holds the whole object and replaces any stale prefix.
        if let destination {
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                if appending, fm.fileExists(atPath: destination.path),
                   ((try fm.attributesOfItem(atPath: destination.path)[.size] as? UInt64) ?? 0) > 0 {
                    let readHandle = try FileHandle(forReadingFrom: location)
                    let writeHandle = try FileHandle(forWritingTo: destination)
                    try writeHandle.seekToEnd()
                    while true {
                        let chunk = try readHandle.read(upToCount: 1 << 20) ?? Data()
                        if chunk.isEmpty { break }
                        try writeHandle.write(contentsOf: chunk)
                    }
                    try readHandle.close()
                    try writeHandle.close()
                } else {
                    if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                    try fm.moveItem(at: location, to: destination)
                }
                eventContinuation.yield((id, .finished(appending: appending)))
            } catch {
                eventContinuation.yield((id, .failed(error: error, resumeData: nil)))
            }
        } else {
            eventContinuation.yield((id, .finished(appending: appending)))
        }
    }

    /// Never forward Authorization across hosts on redirect. Note: for
    /// background sessions the system may follow redirects without calling
    /// this delegate method; the app only sends Authorization to HF hosts
    /// (see RedirectPolicy.isAllowedHFHost), and HF /resolve redirects drop
    /// to CDN hosts that do not need the token.
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(RedirectPolicy.sanitize(request: request,
                                                  original: task.originalRequest ?? request))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        if let error {
            let nsError = error as NSError
            logDelegate("didCompleteWithError task=\(task.taskIdentifier) "
                + "domain=\(nsError.domain) code=\(nsError.code) "
                + "state=\(task.state.rawValue) "
                + "received=\(task.countOfBytesReceived) "
                + "status=\((task.response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let error, let download = task as? URLSessionDownloadTask,
              let id = idFor(download) else { return }
        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        state.withLock {
            _ = $0.tasksByID.removeValue(forKey: id)
            $0.taskKeys.removeValue(forKey: id)
            $0.appending.removeValue(forKey: id)
            $0.destinations.removeValue(forKey: id)
        }
        eventContinuation.yield((id, .failed(error: error, resumeData: resumeData)))
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        BackgroundSessionCoordinator.shared.invokeCompletionHandler(for: identifier)
    }

    private func idFor(_ task: URLSessionDownloadTask) -> TransferID? {
        state.withLock { $0.tasksByID.first(where: { $0.value == task })?.key }
    }
}

/// Holds the system completion handler until the background session drains.
public final class BackgroundSessionCoordinator: @unchecked Sendable {
    public static let shared = BackgroundSessionCoordinator()

    private let handlers = LockedState<[String: @Sendable () -> Void]>([:])

    private init() {}

    public func registerCompletionHandler(_ handler: @escaping @Sendable () -> Void,
                                          for identifier: String) {
        handlers.withLock { $0[identifier] = handler }
    }

    public func invokeCompletionHandler(for identifier: String) {
        let handler = handlers.withLock { $0.removeValue(forKey: identifier) }
        handler?()
    }
}
#endif
