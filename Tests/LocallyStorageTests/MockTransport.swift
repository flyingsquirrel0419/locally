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
    }

    private struct State: Sendable {
        var nextID = 1
        var behaviors: [URL: Behavior] = [:]
        var started: [StartedRequest] = []
        var pausedIDs: Set<TransferID> = []
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
            let record = StartedRequest(url: request.url!,
                                        hasResumeData: resumeData != nil,
                                        rangeHeader: request.value(forHTTPHeaderField: "Range"),
                                        destination: destination)
            s.started.append(record)
            let behavior = s.behaviors[request.url!] ?? .succeed(Data())
            return (id, record, behavior)
        }

        let continuation = self.continuation
        Task {
            // Yield so the manager finishes start() bookkeeping first.
            try? await Task.sleep(nanoseconds: 5_000_000)
            switch behavior {
            case .succeed(let data):
                let existing = (try? Data(contentsOf: record.destination)) ?? Data()
                var offset = Int64(existing.count)
                // Emulate Range-aware server: skip the prefix we already have.
                let payload: Data
                if record.rangeHeader != nil || record.hasResumeData {
                    payload = data.count > Int(offset) ? data.suffix(from: Int(offset)) : Data()
                } else {
                    offset = 0
                    payload = data
                }
                let full = (offset > 0 ? existing : Data()) + payload
                try? FileManager.default.createDirectory(
                    at: record.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? full.write(to: record.destination)
                let total = Int64(full.count)
                continuation.yield((id, .progress(bytesReceived: total / 2, totalBytes: total)))
                continuation.yield((id, .progress(bytesReceived: total, totalBytes: total)))
                continuation.yield((id, .finished))
            case .fail(let error, let resumeData):
                continuation.yield((id, .failed(error: error, resumeData: resumeData)))
            case .failStatus(let code):
                continuation.yield((id, .failed(error: HTTPStatusError(statusCode: code), resumeData: nil)))
            case .hang:
                break  // cancelled externally
            }
        }
        return id
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
