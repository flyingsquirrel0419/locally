import Foundation
import LocallyCore

/// Lifecycle of one downloadable file within a job.
public enum DownloadState: Sendable, Hashable {
    case queued
    case preparing
    case downloading(progress: Double)
    case paused(resumeDataAvailable: Bool)
    case verifying
    case completed
    case failed(LocallyError)
    case cancelled
}

/// Inputs that drive `DownloadReducer`.
public enum DownloadEvent: Sendable, Hashable {
    case enqueue
    case prepare
    case start
    case progress(Double)
    case pause(resumeDataAvailable: Bool)
    case resume
    case verify
    case complete
    case fail(LocallyError)
    case cancel
}

/// Pure state machine for a single file download. Illegal transitions are
/// rejected: the state is returned unchanged and a warning is logged.
public enum DownloadReducer {
    public static func reduce(_ state: DownloadState, _ event: DownloadEvent) -> DownloadState {
        if let next = nextState(state, event) {
            return next
        }
        Log.warning(.download, "illegal transition: \(String(describing: state)) + \(String(describing: event))")
        return state
    }

    private static func nextState(_ state: DownloadState, _ event: DownloadEvent) -> DownloadState? {
        switch (state, event) {
        // From queued
        case (.queued, .prepare): return .preparing
        // From preparing
        case (.preparing, .start): return .downloading(progress: 0)
        case (.preparing, .fail(let e)): return .failed(e)
        // From downloading
        case (.downloading, .progress(let p)): return .downloading(progress: p)
        case (.downloading, .pause(let hasResume)): return .paused(resumeDataAvailable: hasResume)
        case (.downloading, .verify): return .verifying
        case (.downloading, .complete): return .completed
        case (.downloading, .fail(let e)): return .failed(e)
        // From paused
        case (.paused, .resume): return .downloading(progress: 0)
        case (.paused, .fail(let e)): return .failed(e)
        // From verifying
        case (.verifying, .complete): return .completed
        case (.verifying, .fail(let e)): return .failed(e)
        // From failed: may be re-enqueued (retry) or cancelled
        case (.failed, .enqueue): return .queued
        // Cancel is legal from any non-terminal state
        case (.queued, .cancel), (.preparing, .cancel),
             (.downloading, .cancel), (.paused, .cancel),
             (.verifying, .cancel), (.failed, .cancel):
            return .cancelled
        default:
            return nil
        }
    }

    /// Whether a file in this state still needs bytes fetched.
    public static func isPending(_ state: DownloadState) -> Bool {
        switch state {
        case .queued, .preparing, .downloading, .paused, .verifying: return true
        case .completed, .failed, .cancelled: return false
        }
    }
}
