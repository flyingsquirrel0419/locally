import Foundation

/// A tiny lock-protected mutable box. Replacement for
/// `Synchronization.Mutex`, which requires iOS 18/macOS 15 while this
/// package deploys to iOS 17/macOS 14. Uses NSLock, available everywhere.
public final class LockedState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    /// Runs `body` with exclusive access to the value. `body` must not
    /// re-enter `withLock` on the same instance (NSLock is not recursive).
    @discardableResult
    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
