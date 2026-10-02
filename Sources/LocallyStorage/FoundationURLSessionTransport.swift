import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LocallyCore


/// Cross-platform URLSession transport (default on Linux and macOS).
/// Uses a delegate-based download task so it works with
/// swift-corelibs-foundation, which lacks `URLSession.bytes(for:)`.
/// Resume falls back to HTTP Range from the part-file size (the manager
/// passes the existing part file as `destination` and sets the Range header).
public final class FoundationURLSessionTransport: NSObject, DownloadTransport,
        URLSessionDownloadDelegate, @unchecked Sendable {
    public typealias TransferID = Int

    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()
    private struct State: Sendable {
        var nextID: TransferID = 1
        var tasks: [TransferID: URLSessionDownloadTask] = [:]
        var destinations: [TransferID: URL] = [:]
        /// True when the request resumed via Range/resume data: completion
        /// appends the suffix to the part file instead of replacing it.
        var appending: [TransferID: Bool] = [:]
    }
    private let state = LockedState(State())

    private let eventStream: AsyncStream<(TransferID, DownloadTransportEvent)>
    private let eventContinuation: AsyncStream<(TransferID, DownloadTransportEvent)>.Continuation

    public override init() {
        var cont: AsyncStream<(TransferID, DownloadTransportEvent)>.Continuation!
        eventStream = AsyncStream { cont = $0 }
        eventContinuation = cont
        super.init()
    }

    public var events: AsyncStream<(TransferID, DownloadTransportEvent)> { eventStream }

    public func start(request: URLRequest, resumeData: Data?, destination: URL,
                      taskKey: String) async throws -> TransferID {
        // resumeData is a URLSession-background concept; this transport resumes
        // via HTTP Range (the manager already set the header from the part-file
        // size), so resumeData is ignored here. A default session's tasks die
        // with the process, so reattach/task-key bookkeeping is a no-op.
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let resuming = request.value(forHTTPHeaderField: "Range") != nil

        let id = state.withLock { s in
            let id = s.nextID
            s.nextID += 1
            s.destinations[id] = destination
            s.appending[id] = resuming
            return id
        }

        let task = session.downloadTask(with: request)
        task.taskDescription = taskKey
        state.withLock { $0.tasks[id] = task }
        task.resume()
        return id
    }

    public func reattachedTransfers() async -> [String] { [] }

    /// Pause is cooperative: we cannot extract resumeData without the
    /// background-session API, so we cancel and return nil; the manager falls
    /// back to HTTP Range from the part-file size on resume.
    public func pause(_ id: TransferID) async -> Data? {
        await cancel(id)
        return nil
    }

    public func cancel(_ id: TransferID) async {
        let task = state.withLock { s -> URLSessionDownloadTask? in
            s.destinations.removeValue(forKey: id)
            s.appending.removeValue(forKey: id)
            return s.tasks.removeValue(forKey: id)
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
        let (destination, appending) = state.withLock { s -> (URL?, Bool) in
            (s.destinations[id], s.appending[id] ?? false)
        }
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
            eventContinuation.yield((id, .failed(error: HTTPStatusError(statusCode: http.statusCode),
                                                 resumeData: nil)))
            return
        }
        guard let destination else {
            eventContinuation.yield((id, .finished(appending: appending)))
            return
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            // A resuming request (Range header) received only the suffix:
            // append it to the part file's prefix. A full 200 replaces.
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
    }

    /// Never forward Authorization across hosts on redirect (HF /resolve/
    /// bounces to CDN hosts; anything else must not see the token).
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(RedirectPolicy.sanitize(request: request,
                                                  original: task.originalRequest ?? request))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        guard let download = task as? URLSessionDownloadTask,
              let id = idFor(download) else { return }
        state.withLock { s in
            s.tasks.removeValue(forKey: id)
            s.destinations.removeValue(forKey: id)
            s.appending.removeValue(forKey: id)
        }
        if let error {
            #if os(Linux)
            let resumeData: Data? = nil  // key unavailable on corelibs
            #else
            let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            #endif
            eventContinuation.yield((id, .failed(error: error, resumeData: resumeData)))
        }
    }

    private func idFor(_ task: URLSessionDownloadTask) -> TransferID? {
        state.withLock { $0.tasks.first(where: { $0.value == task })?.key }
    }
}
