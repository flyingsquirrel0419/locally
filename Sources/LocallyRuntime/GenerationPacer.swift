import Foundation
import LocallyCore

/// Runtime-agnostic thermal pacing hook. Decode loops await `pace()` between
/// tokens; the app injects a policy-backed implementation whose delay comes
/// from `ResourcePolicyObserver`, while tests and headless builds use the
/// no-op default. Deliberately in LocallyRuntime (not LocallyDevice) so the
/// runtimes depend on nothing beyond this package.
public protocol GenerationPacer: Sendable {
    /// Suspend briefly between generated tokens when the resource policy is
    /// throttling. Must return immediately when not throttling.
    func pace() async
}

/// Default pacer: no pacing. Zero-delay fast path.
public struct NoOpGenerationPacer: GenerationPacer {
    public init() {}
    public func pace() async {}
}

/// Fixed-delay pacer, useful for tests and for the app's policy-backed
/// implementation which reads the current delay from the observer.
public struct FixedDelayGenerationPacer: GenerationPacer {
    public let delayNanoseconds: UInt64

    public init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    public func pace() async {
        guard delayNanoseconds > 0 else { return }
        try? await Task.sleep(nanoseconds: delayNanoseconds)
    }
}
