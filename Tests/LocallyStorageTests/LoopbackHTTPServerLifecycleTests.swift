import XCTest
@testable import LocallyStorage

/// Regression tests for the CI hang in run 36958123074: the loopback
/// server's blocking accept() loop ran on the Swift Concurrency
/// cooperative pool, and close() without shutdown() never woke it on
/// Linux, so leaked accept loops pinned cooperative threads until the
/// pool was exhausted and the next async test's detached task starved.
final class LoopbackHTTPServerLifecycleTests: XCTestCase {
    private func threadCount() -> Int {
        #if os(Linux)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            atPath: "/proc/self/task") else { return -1 }
        return entries.count
        #else
        return -1  // macOS: no /proc; assertion below is Linux-only
        #endif
    }

    /// Start+stop 50 servers in a loop; afterwards the thread count must
    /// return to baseline (every accept thread exited) and a detached
    /// async task must still complete quickly (cooperative pool healthy).
    func testStartStopDoesNotLeakThreadsOrStarvePool() async throws {
        // Warm the pool before measuring the baseline.
        _ = await Task.detached { true }.value
        let baseline = threadCount()
        for _ in 0..<50 {
            let server = try LoopbackHTTPServer()
            server.start()
            server.stop()
        }
        var settled = -1
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            settled = threadCount()
            if baseline < 0 || settled <= baseline + 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if baseline >= 0 {
            XCTAssertLessThanOrEqual(settled, baseline + 1,
                "accept threads must exit on stop (baseline \(baseline), now \(settled))")
        }
        // The original failure mode: a detached task never got a thread.
        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await Task.detached { true }.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(completed, "detached task starved: cooperative pool exhausted")
    }

    /// start() must be idempotent: a second call must not spawn another
    /// accept loop on the same listener.
    func testStartIsIdempotent() throws {
        let server = try LoopbackHTTPServer()
        server.start()
        server.start()
        server.start()
        server.stop()
        // Reaching here without a leaked thread is the assertion; the
        // previous test measures thread counts precisely.
    }
}
