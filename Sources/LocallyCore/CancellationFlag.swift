import Foundation

/// A tiny thread-safe cancellation flag. Runtimes that offload blocking work
/// to `Task.detached` cannot observe `Task.isCancelled` of their caller from
/// inside the detached task (the detached task is never cancelled), so they
/// share this flag with a `withTaskCancellationHandler` instead.
///
/// Backed by `LockedState` (NSLock), so it is safe to set from any thread
/// and read from a library progress handler running on a worker queue.
public final class CancellationFlag: @unchecked Sendable {
    private let state = LockedState(false)

    public init() {}

    /// Idempotent.
    public func cancel() {
        state.withLock { $0 = true }
    }

    public var isCancelled: Bool {
        state.withLock { $0 }
    }
}
