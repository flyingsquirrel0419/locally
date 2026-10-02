import XCTest
@testable import LocallyStorage
import LocallyCore

/// Regression tests for the on-device v0.1.1 report: PAUSE and DELETE did
/// nothing. Root causes pinned here:
///  1. A real URLSession delivers didCompleteWithError(NSURLErrorCancelled)
///     asynchronously after cancel(byProducingResumeData:) / cancel(). The
///     manager still had the transfer mapped, so the cancellation callback
///     was handled as a network failure and the auto-retry restarted the
///     download the user had just paused.
///  2. cancel() removed the job from the store only after several awaits;
///     an event handler queued mid-cancel re-read the job and upserted it
///     back, so the deleted job reappeared.
/// MockTransport now models both URLSession behaviors; every test in this
/// file fails against the pre-fix implementation.
final class DownloadPauseCancelTests: XCTestCase {
    private var tempRoot: URL!
    private var layout: FilesystemLayout!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("dlpause-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        layout = FilesystemLayout(root: tempRoot)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private let urlA = URL(string: "https://example.com/a.bin")!

    private func source(_ url: URL, path: String, bytes: Int, sha256: String? = nil) -> DownloadSource {
        DownloadSource(url: url, relativePath: path, expectedSize: Int64(bytes), sha256: sha256)
    }

    private func sha256(_ data: Data) -> String {
        var h = StreamingSHA256()
        h.update(data)
        return h.finalize()
    }

    private func makeManager(transport: MockTransport) async -> DownloadManager {
        let store = DownloadStore(directory: tempRoot.appendingPathComponent("store"))
        return DownloadManager(store: store, layout: layout, transport: transport)
    }

    private func waitFor(_ timeout: TimeInterval = 5,
                         _ predicate: @escaping @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    /// Pause must stick: the transport's asynchronous NSURLErrorCancelled
    /// callback after pause must not be treated as a retryable failure.
    /// Fails on the old code: the cancelled callback triggered the retry
    /// path and a second start appeared within the 2 s window.
    func testPauseStaysPausedDespiteCancellationCallback() async throws {
        let transport = MockTransport()
        transport.setBehavior(.hang, for: urlA)
        let manager = await makeManager(transport: transport)
        let job = try await manager.enqueue(repoID: "o/m", revision: "main",
                                            sources: [source(urlA, path: "a.bin", bytes: 100)])
        let started = await waitFor { transport.startedRequests.count == 1 }
        XCTAssertTrue(started)

        try await manager.pause(jobID: job.id)
        let paused = await waitFor {
            (try? await manager.jobs().first)?.files[0].state == .paused
        }
        XCTAssertTrue(paused)

        // Wait well past the mock's delayed cancellation callback; the file
        // must remain paused and nothing may restart.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let after = try await manager.jobs().first(where: { $0.id == job.id })
        XCTAssertEqual(after?.files[0].state, .paused,
                       "pause was undone by the transport's cancellation callback")
        XCTAssertEqual(transport.startedRequests.count, 1,
                       "the download restarted after pause")
    }

    /// Cancel removes the job, and the cancelled task's late callbacks must
    /// never resurrect it (actor reentrancy: an event handler queued while
    /// cancel awaited could previously upsert the job back).
    func testCancelRemovesJobAndLateEventsDoNotReviveIt() async throws {
        let transport = MockTransport()
        transport.setBehavior(.hang, for: urlA)
        let manager = await makeManager(transport: transport)
        let job = try await manager.enqueue(repoID: "o/m", revision: "main",
                                            sources: [source(urlA, path: "a.bin", bytes: 100)])
        let started = await waitFor { transport.startedRequests.count == 1 }
        XCTAssertTrue(started)

        try await manager.cancel(jobID: job.id)
        var remaining = try await manager.jobs()
        XCTAssertEqual(remaining.count, 0)

        // Past the mock's delayed cancellation delivery.
        try await Task.sleep(nanoseconds: 500_000_000)
        remaining = try await manager.jobs()
        XCTAssertEqual(remaining.count, 0,
                       "cancelled job reappeared after a late transport event")
        XCTAssertEqual(transport.startedRequests.count, 1,
                       "cancelled download restarted")
    }

    /// Resume after pause restarts from the bytes on disk via HTTP Range and
    /// completes with the full payload verifying byte-for-byte (sha256).
    func testResumeAfterPauseCompletesWithCorrectBytesAndSHA() async throws {
        let data = Data((0..<512).map { UInt8(($0 * 7 + 3) % 256) })
        let digest = sha256(data)
        let transport = MockTransport()
        transport.setBehavior(.hang, for: urlA)
        let manager = await makeManager(transport: transport)
        let job = try await manager.enqueue(repoID: "o/m", revision: "main",
                                            sources: [source(urlA, path: "a.bin", bytes: data.count,
                                                             sha256: digest)])
        let started = await waitFor { transport.startedRequests.count == 1 }
        XCTAssertTrue(started)
        // Half the bytes landed before the user paused.
        let partURL = try layout.partialFileURL(jobID: job.id, relativePath: "a.bin")
        try data.prefix(256).write(to: partURL)

        try await manager.pause(jobID: job.id)
        let paused = await waitFor {
            (try? await manager.jobs().first)?.files[0].state == .paused
        }
        XCTAssertTrue(paused)

        transport.setBehavior(.succeed(data), for: urlA)
        try await manager.resume(jobID: job.id)
        let done = await waitFor {
            (try? await manager.jobs().first)?.files[0].state == .completed
        }
        XCTAssertTrue(done, "resume after pause did not complete")
        XCTAssertEqual(transport.startedRequests.count, 2)
        XCTAssertEqual(transport.startedRequests[1].rangeHeader, "bytes=256-")
        let installed = tempRoot.appendingPathComponent("Models/o_m/main/a.bin")
        XCTAssertEqual(try Data(contentsOf: installed), data)
    }

    /// Cancel raced with an in-flight progress event: the store read in the
    /// progress handler resolves mid-cancel; the job must still end up
    /// deleted and must never come back.
    func testCancelWhileProgressEventInFlightDoesNotResurrectJob() async throws {
        let transport = MockTransport()
        transport.setBehavior(.hang, for: urlA)
        let manager = await makeManager(transport: transport)
        let job = try await manager.enqueue(repoID: "o/m", revision: "main",
                                            sources: [source(urlA, path: "a.bin", bytes: 100)])
        let started = await waitFor { transport.startedRequests.count == 1 }
        XCTAssertTrue(started)

        // Race: fire a progress event and cancel in the same instant. The
        // progress handler's store read interleaves with cancel's awaits.
        transport.injectProgressForStarted(bytesReceived: 10, totalBytes: 100)
        try await manager.cancel(jobID: job.id)
        var remaining = try await manager.jobs()
        XCTAssertEqual(remaining.count, 0)

        try await Task.sleep(nanoseconds: 500_000_000)
        remaining = try await manager.jobs()
        XCTAssertEqual(remaining.count, 0,
                       "job resurrected by a progress event that raced cancel")
    }

    /// Cancel of a paused job (no in-flight transfer) removes the job and
    /// deletes the kept partial bytes.
    func testCancelPausedJobDeletesPartials() async throws {
        let transport = MockTransport()
        transport.setBehavior(.hang, for: urlA)
        let manager = await makeManager(transport: transport)
        let job = try await manager.enqueue(repoID: "o/m", revision: "main",
                                            sources: [source(urlA, path: "a.bin", bytes: 100)])
        let started = await waitFor { transport.startedRequests.count == 1 }
        XCTAssertTrue(started)
        try await manager.pause(jobID: job.id)
        let paused = await waitFor {
            (try? await manager.jobs().first)?.files[0].state == .paused
        }
        XCTAssertTrue(paused)
        let partURL = try layout.partialFileURL(jobID: job.id, relativePath: "a.bin")
        try Data("partial".utf8).write(to: partURL)

        try await manager.cancel(jobID: job.id)
        let remaining = try await manager.jobs()
        XCTAssertEqual(remaining.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.partialDirectory(jobID: job.id).path))
    }

    /// A cancellation that the manager did NOT initiate (system suspended
    /// the background task) pauses the file instead of failing/retrying it.
    func testSystemInitiatedCancellationPausesWithoutRetry() async throws {
        let transport = MockTransport()
        transport.setBehavior(.hang, for: urlA)
        let manager = await makeManager(transport: transport)
        let job = try await manager.enqueue(repoID: "o/m", revision: "main",
                                            sources: [source(urlA, path: "a.bin", bytes: 100)])
        let started = await waitFor { transport.startedRequests.count == 1 }
        XCTAssertTrue(started)

        // The system cancels the task behind the manager's back.
        transport.injectCancellationForStarted()
        let paused = await waitFor {
            (try? await manager.jobs().first)?.files[0].state == .paused
        }
        XCTAssertTrue(paused, "system cancellation must pause, not fail")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(transport.startedRequests.count, 1,
                       "system cancellation triggered an automatic retry")
    }
}
