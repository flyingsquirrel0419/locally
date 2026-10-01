import XCTest
@testable import LocallyCore

final class CancellationFlagTests: XCTestCase {
    func testStartsUncancelled() {
        XCTAssertFalse(CancellationFlag().isCancelled)
    }

    func testCancelIsObserved() {
        let flag = CancellationFlag()
        flag.cancel()
        XCTAssertTrue(flag.isCancelled)
    }

    func testCancelIsIdempotent() {
        let flag = CancellationFlag()
        flag.cancel()
        flag.cancel()
        XCTAssertTrue(flag.isCancelled)
    }

    /// The whole point of the type: a detached task must observe a cancel
    /// signalled on the caller's task (it cannot use Task.isCancelled).
    func testCancelledAcrossDetachedTask() async {
        let flag = CancellationFlag()
        let caller = Task {
            await withTaskCancellationHandler {
                // simulate work: wait for the detached reader to observe
                let observed = await Task.detached { () -> Bool in
                    while !flag.isCancelled {
                        try? await Task.sleep(nanoseconds: 1_000_000)
                    }
                    return true
                }.value
                XCTAssertTrue(observed)
            } onCancel: {
                flag.cancel()
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        caller.cancel()
        _ = await caller.value
        XCTAssertTrue(flag.isCancelled)
    }
}
