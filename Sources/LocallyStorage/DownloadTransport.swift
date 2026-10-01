import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Events for one started download.
public enum DownloadTransportEvent: Sendable {
    case progress(bytesReceived: Int64, totalBytes: Int64?)
    /// The file finished; its bytes are at the destination part file.
    case finished
    case failed(error: Error, resumeData: Data?)
}

/// Transport abstraction used by DownloadManager. Implementations stream
/// events back; the manager owns state, persistence, and policy.
public protocol DownloadTransport: Sendable {
    /// Handle that identifies an in-flight transfer on this transport.
    typealias TransferID = Int

    /// Start (or resume) a transfer. The transport appends received bytes to
    /// `destination`, which already contains any previously downloaded prefix.
    func start(request: URLRequest, resumeData: Data?, destination: URL) async throws -> TransferID

    /// Pause a transfer; returns resume data when the transport supports it.
    func pause(_ id: TransferID) async -> Data?

    func cancel(_ id: TransferID) async

    /// Stream of (transferID, event) pairs.
    var events: AsyncStream<(TransferID, DownloadTransportEvent)> { get }
}
