import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LocallyCore
@testable import LocallyStorage

/// Test transport: scriptable bytes, controllable timing, no network.
final class MockTransport: DownloadTransport, @unchecked Sendable {
    typealias TransferID = Int

    struct StartedRequest: Sendable {
        var url: URL
        var hasResumeData: Bool
        var rangeHeader: String?
        var destination: URL
    }

    enum Behavior: Sendable {
        case succeed(Data)
        case fail(Error, resumeData: Data?)
        case failStatus(Int)
        case hang   // never completes until cancelled
        /// Write a prefix of the payload, report progress, then fail.
        /// Emulates a connection drop mid-file; the partial bytes stay on
        /// disk for a Range resume.
        case failMidway(Data, afterBytes: Int, error: Error)
        /// Bytes land on disk but the finish fails with an injected I/O
        /// error (e.g. ENOSPC), as if the final write hit a full disk.
        case writeFailure(Data, error: Error)
        /// Fail the first `times` starts with `error`, then succeed.
        case failThenSucceed(Data, times: Int, error: Error)
    }

    private struct State: Sendable {
        var nextID = 1
        var behaviors: [URL: Behavior] = [:]
        var started: [StartedRequest] = []
        var pausedIDs: Set<TransferID> = []
        var startCounts: [URL: Int] = [:]
    }

    private let state = LockedState(State())

    let stream: AsyncStream<(TransferID, DownloadTransportEvent)>
    private let continuation: AsyncStream<(TransferID, DownloadTransportEvent)>.Continuation

    init() {
        var cont: AsyncStream<(TransferID, DownloadTransportEvent)>.Continuation!
        stream = AsyncStream { cont = $0 }
        continuation = cont
    }

    var events: AsyncStream<(TransferID, DownloadTransportEvent)> { stream }

    func setBehavior(_ behavior: Behavior, for url: URL) {
        state.withLock { $0.behaviors[url] = behavior }
    }

    var startedRequests: [StartedRequest] {
        state.withLock { $0.started }
    }

    func start(request: URLRequest, resumeData: Data?, destination: URL) async throws -> TransferID {
        let (id, record, behavior) = state.withLock { s -> (TransferID, StartedRequest, Behavior) in
            let id = s.nextID
            s.nextID += 1
            // Mirror FoundationURLSessionTransport: resume via HTTP Range
            // computed from the destination part-file size, so tests observe
            // the same contract the real transport offers.
            var range = request.value(forHTTPHeaderField: "Range")
            if range == nil,
               let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? UInt64) ?? nil,
               size > 0 {
                range = "bytes=\(size)-"
            }
            let record = StartedRequest(url: request.url!,
                                        hasResumeData: resumeData != nil,
                                        rangeHeader: range,
                                        destination: destination)
            s.started.append(record)
            var behavior = s.behaviors[request.url!] ?? .succeed(Data())
            if case .failThenSucceed(let data, let times, let error) = behavior {
                let seen = s.startCounts[request.url!] ?? 0
                s.startCounts[request.url!] = seen + 1
                behavior = seen < times ? .fail(error, resumeData: nil) : .succeed(data)
            }
            return (id, record, behavior)
        }

        let continuation = self.continuation
        Task {
            // Yield so the manager finishes start() bookkeeping first.
            try? await Task.sleep(nanoseconds: 5_000_000)
            switch behavior {
            case .succeed(let data):
                Self.writeSuccess(data: data, record: record, continuation: continuation, id: id)
            case .fail(let error, let resumeData):
                continuation.yield((id, .failed(error: error, resumeData: resumeData)))
            case .failStatus(let code):
                continuation.yield((id, .failed(error: HTTPStatusError(statusCode: code), resumeData: nil)))
            case .hang:
                break  // cancelled externally
            case .failMidway(let data, let afterBytes, let error):
                // Persist only the prefix, report it as progress, then fail:
                // a mid-file network drop with bytes already on disk.
                try? FileManager.default.createDirectory(
                    at: record.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let prefix = data.prefix(afterBytes)
                try? Data(prefix).write(to: record.destination)
                continuation.yield((id, .progress(bytesReceived: Int64(prefix.count),
                                                  totalBytes: Int64(data.count))))
                continuation.yield((id, .failed(error: error, resumeData: nil)))
            case .writeFailure(let data, let error):
                // The download streamed bytes but the sink failed (ENOSPC):
                // only a prefix made it to disk; the rest is lost.
                try? FileManager.default.createDirectory(
                    at: record.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let partial = data.prefix(data.count / 2)
                try? Data(partial).write(to: record.destination)
                continuation.yield((id, .progress(bytesReceived: Int64(partial.count),
                                                  totalBytes: Int64(data.count))))
                continuation.yield((id, .failed(error: error, resumeData: nil)))
            case .failThenSucceed:
                break  // resolved to .fail/.succeed at start() time
            }
        }
        return id
    }

    private static func writeSuccess(
        data: Data, record: StartedRequest,
        continuation: AsyncStream<(TransferID, DownloadTransportEvent)>.Continuation,
        id: TransferID
    ) {
        let existing = (try? Data(contentsOf: record.destination)) ?? Data()
        // Emulate the server: a Range request (or resume-data restart)
        // returns only the missing suffix, appended to the kept prefix; a
        // plain GET returns the whole object and REPLACES whatever is there.
        let full: Data
        if record.rangeHeader != nil || record.hasResumeData {
            let offset = Int64(existing.count)
            let payload = data.count > Int(offset) ? data.suffix(from: Int(offset)) : Data()
            full = existing + payload
        } else {
            full = data
        }
        try? FileManager.default.createDirectory(
            at: record.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? full.write(to: record.destination)
        let total = Int64(full.count)
        continuation.yield((id, .progress(bytesReceived: total / 2, totalBytes: total)))
        continuation.yield((id, .progress(bytesReceived: total, totalBytes: total)))
        continuation.yield((id, .finished))
    }

    func pause(_ id: TransferID) async -> Data? {
        state.withLock { $0.pausedIDs.insert(id) }
        return Data("mock-resume".utf8)
    }

    func cancel(_ id: TransferID) async {}

    func wasPaused(_ id: TransferID) -> Bool {
        state.withLock { $0.pausedIDs.contains(id) }
    }
}
