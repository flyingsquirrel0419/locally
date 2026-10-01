import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LocallyCore
import Synchronization

/// Cross-platform URLSession transport (default on Linux and macOS).
/// Uses a delegate-based download task so it works with
/// swift-corelibs-foundation, which lacks `URLSession.bytes(for:)`.
/// Resume falls back to HTTP Range from the part-file size (the manager
/// passes the existing part file as `destination`).
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
    }
    private let state = Mutex(State())

    private let eventStream: AsyncStream<(TransferID, DownloadTransportEvent)>
    private let eventContinuation: AsyncStream<(TransferID, DownloadTransportEvent)>.Continuation

    public override init() {
        var cont: AsyncStream<(TransferID, DownloadTransportEvent)>.Continuation!
        eventStream = AsyncStream { cont = $0 }
        eventContinuation = cont
        super.init()
    }

    public var events: AsyncStream<(TransferID, DownloadTransportEvent)> { eventStream }

    public func start(request: URLRequest, resumeData: Data?, destination: URL) async throws -> TransferID {
        // resumeData is a URLSession-background concept; this transport resumes
        // via HTTP Range from the part-file size, so resumeData is ignored here.
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var offset: Int64 = 0
        if fm.fileExists(atPath: destination.path) {
            offset = Int64((try fm.attributesOfItem(atPath: destination.path)[.size] as? UInt64) ?? 0)
        }
        var req = request
        if offset > 0 {
            req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        let id = state.withLock { s in
            let id = s.nextID
            s.nextID += 1
            s.destinations[id] = destination
            return id
        }

        let task = session.downloadTask(with: req)
        state.withLock { $0.tasks[id] = task }
        task.resume()
        return id
    }

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
        let destination = state.withLock { $0.destinations[id] }
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
            eventContinuation.yield((id, .failed(error: HTTPStatusError(statusCode: http.statusCode),
                                                 resumeData: nil)))
            return
        }
        guard let destination else {
            eventContinuation.yield((id, .finished))
            return
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            // If a partial prefix exists, append the new bytes; otherwise move.
            if fm.fileExists(atPath: destination.path),
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
            eventContinuation.yield((id, .finished))
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
