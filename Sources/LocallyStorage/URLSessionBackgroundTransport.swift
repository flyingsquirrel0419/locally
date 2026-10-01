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

    private let lock = NSLock()
    private var session: URLSession!
    private var nextID: TransferID = 1
    private var tasksByID: [TransferID: URLSessionDownloadTask] = [:]
    private var destinations: [TransferID: URL] = [:]

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
            self.lock.lock()
            defer { self.lock.unlock() }
            for task in tasks {
                guard let download = task as? URLSessionDownloadTask,
                      let description = task.taskDescription,
                      !description.isEmpty else { continue }
                let id = self.nextID
                self.nextID += 1
                self.tasksByID[id] = download
            }
        }
    }

    public var events: AsyncStream<(TransferID, DownloadTransportEvent)> { eventStream }

    public func start(request: URLRequest, resumeData: Data?, destination: URL) async throws -> TransferID {
        lock.lock()
        let id = nextID
        nextID += 1
        destinations[id] = destination
        lock.unlock()

        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: request)
        }
        // taskDescription carries the correlation across process restarts.
        task.taskDescription = "\(id)"
        task.resume()
        lock.lock()
        tasksByID[id] = task
        lock.unlock()
        return id
    }

    public func pause(_ id: TransferID) async -> Data? {
        await withCheckedContinuation { continuation in
            lock.lock()
            let task = tasksByID[id]
            lock.unlock()
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
        lock.lock()
        let task = tasksByID.removeValue(forKey: id)
        destinations.removeValue(forKey: id)
        lock.unlock()
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
        lock.lock()
        let destination = destinations.removeValue(forKey: id)
        tasksByID.removeValue(forKey: id)
        lock.unlock()
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

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        guard let error, let download = task as? URLSessionDownloadTask,
              let id = idFor(download) else { return }
        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        lock.lock()
        tasksByID.removeValue(forKey: id)
        lock.unlock()
        eventContinuation.yield((id, .failed(error: error, resumeData: resumeData)))
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        BackgroundSessionCoordinator.shared.invokeCompletionHandler(for: Self.sessionIdentifier)
    }

    private func idFor(_ task: URLSessionDownloadTask) -> TransferID? {
        lock.lock()
        defer { lock.unlock() }
        return tasksByID.first(where: { $0.value == task })?.key
    }
}

/// Holds the system completion handler until the background session drains.
public final class BackgroundSessionCoordinator: @unchecked Sendable {
    public static let shared = BackgroundSessionCoordinator()

    private let lock = NSLock()
    private var handlers: [String: () -> Void] = [:]

    private init() {}

    public func registerCompletionHandler(_ handler: @escaping () -> Void, for identifier: String) {
        lock.lock()
        handlers[identifier] = handler
        lock.unlock()
    }

    public func invokeCompletionHandler(for identifier: String) {
        lock.lock()
        let handler = handlers.removeValue(forKey: identifier)
        lock.unlock()
        handler?()
    }
}
#endif
