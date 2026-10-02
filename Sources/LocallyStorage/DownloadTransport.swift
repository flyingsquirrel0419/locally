import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Events for one started download.
public enum DownloadTransportEvent: Sendable {
    case progress(bytesReceived: Int64, totalBytes: Int64?)
    /// The file finished. `appending` is true when the request carried a
    /// Range header or resume data and the transport appended the received
    /// suffix to the existing part file; false means the destination holds
    /// the full object (the previous part file was replaced).
    case finished(appending: Bool)
    case failed(error: Error, resumeData: Data?)
}

/// Transport abstraction used by DownloadManager. Implementations stream
/// events back; the manager owns state, persistence, and policy.
public protocol DownloadTransport: Sendable {
    /// Handle that identifies an in-flight transfer on this transport.
    typealias TransferID = Int

    /// Start (or resume) a transfer. The transport appends received bytes to
    /// `destination`, which already contains any previously downloaded prefix.
    /// `taskKey` is a stable correlation string ("<jobID>|<fileIndex>") the
    /// transport may persist on the underlying task (e.g. URLSession's
    /// taskDescription) so transfers surviving a process relaunch can be
    /// reattached and reported through `reattachedTransfers` on the next
    /// `start` call.
    func start(request: URLRequest, resumeData: Data?, destination: URL,
               taskKey: String) async throws -> TransferID

    /// Keys of transfers that survived an app relaunch and were reattached
    /// since the last call. The manager maps each "<jobID>|<fileIndex>" key
    /// back to its persisted job file and rebinds the event stream.
    func reattachedTransfers() async -> [String]

    /// Pause a transfer; returns resume data when the transport supports it.
    func pause(_ id: TransferID) async -> Data?

    func cancel(_ id: TransferID) async

    /// Stream of (transferID, event) pairs.
    var events: AsyncStream<(TransferID, DownloadTransportEvent)> { get }
}
