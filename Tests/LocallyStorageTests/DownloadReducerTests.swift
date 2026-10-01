import XCTest
@testable import LocallyStorage
import LocallyCore

final class DownloadReducerTests: XCTestCase {
    private let netError = LocallyError.network(userMessage: "net", technicalDetail: "x")

    func testHappyPath() {
        var s: DownloadState = .queued
        s = DownloadReducer.reduce(s, .prepare)
        XCTAssertEqual(s, .preparing)
        s = DownloadReducer.reduce(s, .start)
        XCTAssertEqual(s, .downloading(progress: 0))
        s = DownloadReducer.reduce(s, .progress(0.5))
        XCTAssertEqual(s, .downloading(progress: 0.5))
        s = DownloadReducer.reduce(s, .verify)
        XCTAssertEqual(s, .verifying)
        s = DownloadReducer.reduce(s, .complete)
        XCTAssertEqual(s, .completed)
    }

    func testPauseResume() {
        var s = DownloadReducer.reduce(DownloadState.queued, .prepare)
        s = DownloadReducer.reduce(s, .start)
        s = DownloadReducer.reduce(s, .pause(resumeDataAvailable: true))
        XCTAssertEqual(s, .paused(resumeDataAvailable: true))
        // Resume re-queues; the scheduling pump owns prepare/start.
        s = DownloadReducer.reduce(s, .resume)
        XCTAssertEqual(s, .queued)
        s = DownloadReducer.reduce(s, .prepare)
        s = DownloadReducer.reduce(s, .start)
        XCTAssertEqual(s, .downloading(progress: 0))
    }

    func testFailureFromDownloadingAndVerifying() {
        let downloading = DownloadState.downloading(progress: 0.2)
        XCTAssertEqual(DownloadReducer.reduce(downloading, .fail(netError)), .failed(netError))
        XCTAssertEqual(DownloadReducer.reduce(.verifying, .fail(netError)), .failed(netError))
    }

    func testFailedCanRequeueForRetry() {
        let failed = DownloadState.failed(netError)
        XCTAssertEqual(DownloadReducer.reduce(failed, .enqueue), .queued)
    }

    func testCancelFromAllNonTerminalStates() {
        let states: [DownloadState] = [.queued, .preparing, .downloading(progress: 0.3),
                                       .paused(resumeDataAvailable: false), .verifying, .failed(netError)]
        for state in states {
            XCTAssertEqual(DownloadReducer.reduce(state, .cancel), .cancelled, "\(state)")
        }
    }

    func testIllegalTransitionsRejectedUnchanged() {
        // queued cannot jump to downloading/complete/paused
        XCTAssertEqual(DownloadReducer.reduce(.queued, .start), .queued)
        XCTAssertEqual(DownloadReducer.reduce(.queued, .complete), .queued)
        XCTAssertEqual(DownloadReducer.reduce(.queued, .pause(resumeDataAvailable: false)), .queued)
        // preparing cannot complete
        XCTAssertEqual(DownloadReducer.reduce(.preparing, .complete), .preparing)
        // paused cannot complete or verify
        XCTAssertEqual(DownloadReducer.reduce(.paused(resumeDataAvailable: true), .complete),
                       .paused(resumeDataAvailable: true))
        XCTAssertEqual(DownloadReducer.reduce(.paused(resumeDataAvailable: true), .verify),
                       .paused(resumeDataAvailable: true))
        // terminal states absorb everything except allowed exits
        XCTAssertEqual(DownloadReducer.reduce(.completed, .cancel), .completed)
        XCTAssertEqual(DownloadReducer.reduce(.completed, .enqueue), .completed)
        XCTAssertEqual(DownloadReducer.reduce(.cancelled, .resume), .cancelled)
        XCTAssertEqual(DownloadReducer.reduce(.cancelled, .enqueue), .cancelled)
        // verifying cannot go back to downloading
        XCTAssertEqual(DownloadReducer.reduce(.verifying, .progress(0.9)), .verifying)
        // failed cannot resume directly (must re-enqueue first)
        XCTAssertEqual(DownloadReducer.reduce(.failed(netError), .resume), .failed(netError))
    }

    func testIsPending() {
        XCTAssertTrue(DownloadReducer.isPending(.queued))
        XCTAssertTrue(DownloadReducer.isPending(.downloading(progress: 0.1)))
        XCTAssertTrue(DownloadReducer.isPending(.paused(resumeDataAvailable: true)))
        XCTAssertTrue(DownloadReducer.isPending(.verifying))
        XCTAssertFalse(DownloadReducer.isPending(.completed))
        XCTAssertFalse(DownloadReducer.isPending(.failed(netError)))
        XCTAssertFalse(DownloadReducer.isPending(.cancelled))
    }
}
