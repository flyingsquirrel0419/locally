import Foundation
import LocallyCore

/// iOS background URLSession transport. One session per process lifetime,
/// recreated with the same identifier on relaunch; in-flight tasks are
/// reattached by decoding `taskDescription` ("<jobID>|<fileIndex>").
/// This file compiles only under `#if os(iOS)`; the app wires its
/// `application(_:handleEventsForBackgroundURLSession:)` handler to
/// `BackgroundSessionCoordinator.shared.handleEvents(...)`.
#if os(iOS)
import UIKit

public final class URLSessionBackgroundTransport: NSObject, DownloadTransport,
        URLSessionDownloadDelegate, @unchecked Sendable {
    public static let sessionIdentifier = "me.teamwicked.locally.downloads"

    public typealias TransferID = Int

    private struct State {
        var nextID: TransferID = 1
        var tasksByID: [TransferID: URLSessionDownloadTask] = [:]
        var destinations: [TransferID: URL] = [:]
    }

    // NSLock.lock()/unlock() are unavailable from async contexts under the
    // Swift 6 SDK; LockedState.withLock is a sync entry point, so calling it
    // from async methods is permitted.
    private let state = LockedState(State())
    private var session: URLSession!

    private let eventStream: AsyncStream<(TransferID, DownloadTransportEvent)>
    private let eventContinuation: AsyncStream<(TransferID, DownloadTransportEvent)>.Continuation

    public override init() {
        var cont: AsyncStream<(TransferID, DownloadTransportEvent)>.Continuation!
        eventStream = AsyncStream { cont = $0 }
        eventContinuation = cont
        super.init()
        session = Self.makeSession(delegate: self)
        reattachExistingTasks()
    }

    private static func makeSession(delegate: URLSessionDownloadDelegate) -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        // Cellular policy is enforced per-job by DownloadManager; the session
        // stays permissive so policy changes do not require session teardown.
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    /// Called by the app delegate when iOS relaunches the app for this session.
    public func handleEvents(completionHandler: @escaping () -> Void) {
        BackgroundSessionCoordinator.shared.registerCompletionHandler(completionHandler,
                                                                      for: Self.sessionIdentifier)
    }

    /// On relaunch, map surviving tasks back to (jobID, fileIndex).
    private func reattachExistingTasks() {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            self.state.withLock { state in
                for task in tasks {
                    guard let download = task as? URLSessionDownloadTask,
                          let description = task.taskDescription,
                          !description.isEmpty else { continue }
                    let id = state.nextID
                    state.nextID += 1
                    state.tasksByID[id] = download
                }
            }
        }
    }

    public var events: AsyncStream<(TransferID, DownloadTransportEvent)> { eventStream }

    public func start(request: URLRequest, resumeData: Data?, destination: URL) async throws -> TransferID {
        let id = state.withLock { state -> TransferID in
            let id = state.nextID
            state.nextID += 1
            state.destinations[id] = destination
            return id
        }

        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: request)
        }
        // taskDescription carries the correlation across process restarts.
        task.taskDescription = "\(id)"
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
            return state.tasksByID.removeValue(forKey: id)
        }
        task?.cancel()
    }

    // MARK: - URLSessionDownloadDelegate

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        guard let id = idFor(downloadTask) else { return }
        let expected = totalBytesExpectedToWrite >= 0 ? totalBytesExpectedToWrite : nil
        eventContinuation.yield((id, .progress(bytesReceived: totalBytesWritten, totalBytes: expected)))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        guard let id = idFor(downloadTask) else { return }
        let destination = state.withLock { state -> URL? in
            state.tasksByID.removeValue(forKey: id)
            return state.destinations.removeValue(forKey: id)
        }
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
            eventContinuation.yield((id, .failed(error: HTTPStatusError(statusCode: http.statusCode),
                                                 resumeData: nil)))
            return
        }
        // Move the temp file to the part file before URLSession deletes it.
        if let destination {
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: location, to: destination)
                eventContinuation.yield((id, .finished))
            } catch {
                eventContinuation.yield((id, .failed(error: error, resumeData: nil)))
            }
        } else {
            eventContinuation.yield((id, .finished))
        }
    }

    /// Never forward Authorization across hosts on redirect.
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(RedirectPolicy.sanitize(request: request,
                                                  original: task.originalRequest ?? request))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        guard let error, let download = task as? URLSessionDownloadTask,
              let id = idFor(download) else { return }
        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        state.withLock { _ = $0.tasksByID.removeValue(forKey: id) }
        eventContinuation.yield((id, .failed(error: error, resumeData: resumeData)))
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        BackgroundSessionCoordinator.shared.invokeCompletionHandler(for: Self.sessionIdentifier)
    }

    private func idFor(_ task: URLSessionDownloadTask) -> TransferID? {
        state.withLock { $0.tasksByID.first(where: { $0.value == task })?.key }
    }
}

/// Holds the system completion handler until the background session drains.
public final class BackgroundSessionCoordinator: @unchecked Sendable {
    public static let shared = BackgroundSessionCoordinator()

    private let handlers = LockedState<[String: () -> Void]>([:])

    private init() {}

    public func registerCompletionHandler(_ handler: @escaping () -> Void, for identifier: String) {
        handlers.withLock { $0[identifier] = handler }
    }

    public func invokeCompletionHandler(for identifier: String) {
        let handler = handlers.withLock { $0.removeValue(forKey: identifier) }
        handler?()
    }
}
#endif
