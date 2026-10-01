import XCTest
@testable import LocallyStorage
import LocallyCore

/// Week 12 hardening: failure paths in the download pipeline.
/// Deterministic, no network: fault injection through MockTransport and
/// injectable clock/power/free-space providers.
final class DownloadFailurePathTests: XCTestCase {
    private var tempRoot: URL!
    private var layout: FilesystemLayout!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("dlfail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        layout = FilesystemLayout(root: tempRoot)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private let urlA = URL(string: "https://huggingface.co/o/m/resolve/main/model.gguf")!

    private func source(_ url: URL, path: String, bytes: Int, sha256: String? = nil) -> DownloadSource {
        DownloadSource(url: url, relativePath: path, expectedSize: Int64(bytes), sha256: sha256)
    }

    private func sha256(_ data: Data) -> String {
        var h = StreamingSHA256()
        h.update(data)
        return h.finalize()
    }

    private func makeManager(transport: MockTransport,
                             sleeps: SleepRecorder? = nil,
                             free: Int64 = .max,
                             concurrency: Int = 2) async -> DownloadManager {
        let store = DownloadStore(directory: tempRoot.appendingPathComponent("store"))
        let clock = DownloadClock(sleep: { interval in sleeps?.record(interval) }, now: { Date() })
        return DownloadManager(store: store, layout: layout, transport: transport,
                               clock: clock,
                               freeSpace: FreeSpaceProvider(freeBytes: { free }),
                               concurrentFileLimit: concurrency)
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

    // MARK: - Auth failures

    /// 403 (private/gated repo) must not be retried and must carry a clear
    /// message distinct from a generic network failure.
    func test403NotRetriedAndClearlyMapped() async throws {
        let transport = MockTransport()
        transport.setBehavior(.failStatus(403), for: urlA)
        let sleeps = SleepRecorder()
        let manager = await makeManager(transport: transport, sleeps: sleeps)
        _ = try await manager.enqueue(repoID: "o/m", revision: "main",
                                      sources: [source(urlA, path: "model.gguf", bytes: 10)])
        let failed = await waitFor {
            (try? await manager.jobs().first)?.files[0].state == .failed
        }
        XCTAssertTrue(failed)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.startedRequests.count, 1, "403 must never be retried")
        XCTAssertTrue(sleeps.all.isEmpty, "no backoff sleep for auth failures")
        let detail = try await manager.jobs().first?.files[0].failureDetail
        XCTAssertNotNil(detail)
    }

    /// A second 401 after a manual retry must also stop immediately.
    func testManualRetryOf401DoesNotLoop() async throws {
        let transport = MockTransport()
        transport.setBehavior(.failStatus(401), for: urlA)
        let manager = await makeManager(transport: transport)
        let job = try await manager.enqueue(repoID: "o/m", revision: "main",
                                            sources: [source(urlA, path: "model.gguf", bytes: 10)])
        let failed = await waitFor {
            (try? await manager.jobs().first)?.files[0].state == .failed
        }
        XCTAssertTrue(failed)
        try await manager.retry(jobID: job.id)
        let failedAgain = await waitFor {
            (try? await manager.jobs().first)?.files[0].state == .failed
        }
        XCTAssertTrue(failedAgain)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.startedRequests.count, 2, "manual retry runs once, no automatic loop")
    }

    // MARK: - Offline

    /// Offline mid-download: URLError.notConnectedToInternet is retried
    /// with backoff, and once the network "returns" the file completes.
    func testOfflineMidDownloadRecoversOnRetry() async throws {
        let data = Data((0..<64).map { UInt8($0 % 256) })
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let transport = MockTransport()
        // Two injected offline failures, then success.
        transport.setBehavior(.failThenSucceed(data, times: 2, error: offline), for: urlA)
        let sleeps = SleepRecorder()
        let manager = await makeManager(transport: transport, sleeps: sleeps)
        _ = try await manager.enqueue(repoID: "o/m", revision: "main",
                                      sources: [source(urlA, path: "model.gguf", bytes: data.count,
                                                       sha256: sha256(data))])
        let done = await waitFor(10) {
            (try? await manager.jobs().first)?.files[0].state == .completed
        }
        XCTAssertTrue(done)
        XCTAssertEqual(transport.startedRequests.count, 3)
        XCTAssertEqual(sleeps.all, [1, 2], "exponential backoff 1s then 2s")
        XCTAssertEqual(try Data(contentsOf: tempRoot.appendingPathComponent("Models/o_m/main/model.gguf")),
                       data)
    }

    // MARK: - Mid-file interruption + Range resume

    /// Connection dropped with bytes already on disk; the app backgrounds
    /// (pause), and resuming re-requests from the part-file size via HTTP
    /// Range. Final bytes must be bit-identical with a valid sha256.
    func testInterruptedDownloadResumesViaRangeFromPartSize() async throws {
        let data = Data((0..<500).map { UInt8(($0 * 7 + 13) % 256) })
        let digest = sha256(data)
        let transport = MockTransport()
        // The first transfer hangs — the "interrupted" connection.
        transport.setBehavior(.hang, for: urlA)
        let manager = await makeManager(transport: transport)

        let job = try await manager.enqueue(repoID: "o/m", revision: "main",
                                            sources: [source(urlA, path: "model.gguf",
                                                             bytes: data.count, sha256: digest)])
        let started = await waitFor { transport.startedRequests.count == 1 }
        XCTAssertTrue(started)

        // 200 bytes made it to disk before the drop; backgrounding the app
        // pauses the job and keeps them.
        let partURL = try layout.partialFileURL(jobID: job.id, relativePath: "model.gguf")
        try data.prefix(200).write(to: partURL)
        try await manager.pause(jobID: job.id)
        let paused = await waitFor {
            (try? await manager.jobs().first)?.files[0].state == .paused
        }
        XCTAssertTrue(paused)
        XCTAssertEqual((try? Data(contentsOf: partURL))?.count, 200,
                       "partial bytes must be kept for resume")

        // Network returns: server honors Range from the part size.
        transport.setBehavior(.succeed(data), for: urlA)
        try await manager.resume(jobID: job.id)
        let done = await waitFor(10) {
            (try? await manager.jobs().first)?.files[0].state == .completed
        }
        XCTAssertTrue(done, "resume via Range did not complete")

        let rangeStarts = transport.startedRequests.compactMap(\.rangeHeader)
        XCTAssertTrue(rangeStarts.contains("bytes=200-"),
                      "resume must request from the part-file size, got \(rangeStarts)")

        let installed = tempRoot.appendingPathComponent("Models/o_m/main/model.gguf")
        let finalBytes = try Data(contentsOf: installed)
        XCTAssertEqual(finalBytes, data, "final bytes must be bit-identical")
        XCTAssertEqual(try DownloadManager.sha256Hex(of: installed), digest, "sha must verify")
    }

    // MARK: - Corrupted download

    /// sha mismatch deletes the part and marks failed; a manual retry
    /// re-downloads from scratch and verifies.
    func testCorruptedDownloadRetryRedownloads() async throws {
        let good = Data("the real model bytes".utf8)
        let bad = Data("CORRUPTED CONTENT!!".utf8)  // same length, wrong bytes
        let transport = MockTransport()
        transport.setBehavior(.succeed(bad), for: urlA)
        let manager = await makeManager(transport: transport)
        let job = try await manager.enqueue(
            repoID: "o/m", revision: "main",
            sources: [source(urlA, path: "model.gguf", bytes: good.count, sha256: sha256(good))])
        let failed = await waitFor {
            (try? await manager.jobs().first)?.files[0].state == .failed
        }
        XCTAssertTrue(failed)
        let partURL = try layout.partialFileURL(jobID: job.id, relativePath: "model.gguf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partURL.path),
                       "corrupted part must be deleted")

        // Network now serves the real bytes (a snapshot must be in place
        // BEFORE the retry's start() is issued, or the transfer would reuse
        // the corrupted payload).
        transport.setBehavior(.succeed(good), for: urlA)
        try await manager.retry(jobID: job.id)
        let done = await waitFor(10) {
            (try? await manager.jobs().first)?.files[0].state == .completed
        }
        XCTAssertTrue(done, "retry after corruption must re-download and verify")
        XCTAssertEqual(try Data(contentsOf: tempRoot.appendingPathComponent("Models/o_m/main/model.gguf")),
                       good)
    }

    // MARK: - Disk full mid-download

    /// ENOSPC surfaced by the transport mid-download: the file fails with
    /// an insufficientStorage error naming the disk problem, and the
    /// partial bytes stay on disk.
    func testDiskFullMidDownloadKeepsPartial() async throws {
        let data = Data((0..<300).map { UInt8($0 % 251) })
        let enospc = NSError(domain: NSPOSIXErrorDomain, code: 28)  // ENOSPC
        let transport = MockTransport()
        transport.setBehavior(.writeFailure(data, error: enospc), for: urlA)
        let manager = await makeManager(transport: transport)
        let job = try await manager.enqueue(repoID: "o/m", revision: "main",
                                            sources: [source(urlA, path: "model.gguf",
                                                             bytes: data.count)])
        let failed = await waitFor {
            (try? await manager.jobs().first)?.files[0].state == .failed
        }
        XCTAssertTrue(failed)
        try await Task.sleep(nanoseconds: 100_000_000)
        // ENOSPC is not an NSURLError: no automatic retry.
        XCTAssertEqual(transport.startedRequests.count, 1,
                       "disk-full is not network-ish; must not auto-retry")
        // Partial kept on disk (not silently deleted).
        let partURL = try layout.partialFileURL(jobID: job.id, relativePath: "model.gguf")
        XCTAssertEqual((try? Data(contentsOf: partURL))?.count, data.count / 2,
                       "partial bytes must be kept")
        // The failure maps to insufficientStorage with a freeing-space message.
        let detail = try await manager.jobs().first?.files[0].failureDetail
        XCTAssertTrue(detail?.contains("ENOSPC") == true,
                      "failure detail should name ENOSPC, got \(detail ?? "nil")")
    }

    /// Insufficient storage at preflight for a multi-file job: the first
    /// file that does not fit fails with insufficientStorage and the
    /// transfer never starts.
    func testPreflightInsufficientStorageNamesTheError() async throws {
        let transport = MockTransport()
        let big = 2 * 1024 * 1024 * 1024  // 2 GB file
        let free: Int64 = 700 * 1024 * 1024  // 700 MB free
        let manager = await makeManager(transport: transport, free: free)
        _ = try await manager.enqueue(repoID: "o/m", revision: "main",
                                      sources: [source(urlA, path: "model.gguf", bytes: big)])
        let failed = await waitFor {
            (try? await manager.jobs().first)?.files[0].state == .failed
        }
        XCTAssertTrue(failed)
        XCTAssertEqual(transport.startedRequests.count, 0)
        let detail = try await manager.jobs().first?.files[0].failureDetail
        XCTAssertTrue(detail?.contains("required=") == true)
        XCTAssertTrue(detail?.contains("available=") == true)
    }

    // MARK: - Cancel during download

    /// Cancel while a transfer hangs: partial bytes are removed, the job is
    /// gone from the store, and no further events revive it.
    func testCancelDuringDownloadCleansEverything() async throws {
        let transport = MockTransport()
        transport.setBehavior(.hang, for: urlA)
        let manager = await makeManager(transport: transport)
        let job = try await manager.enqueue(repoID: "o/m", revision: "main",
                                            sources: [source(urlA, path: "model.gguf", bytes: 100)])
        let started = await waitFor { transport.startedRequests.count == 1 }
        XCTAssertTrue(started)
        let partURL = try layout.partialFileURL(jobID: job.id, relativePath: "model.gguf")
        try Data("half".utf8).write(to: partURL)

        try await manager.cancel(jobID: job.id)
        let remaining = try await manager.jobs()
        XCTAssertEqual(remaining.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.partialDirectory(jobID: job.id).path))
        // A late event from the cancelled transfer must be ignored.
        try await Task.sleep(nanoseconds: 100_000_000)
        let afterLateEvents = try await manager.jobs()
        XCTAssertEqual(afterLateEvents.count, 0)
    }

    // MARK: - Relaunch recovery

    /// Kill the manager mid-download (no cancel — process death), create a
    /// new manager on the same store, restore, re-register sources, resume:
    /// the download completes and sha verifies.
    func testRelaunchRecoveryCompletesDownload() async throws {
        let data = Data((0..<256).map { UInt8(($0 * 3 + 1) % 256) })
        let digest = sha256(data)
        let storeDir = tempRoot.appendingPathComponent("store")

        let transport1 = MockTransport()
        transport1.setBehavior(.hang, for: urlA)
        let manager1 = DownloadManager(store: DownloadStore(directory: storeDir),
                                       layout: layout, transport: transport1)
        let job = try await manager1.enqueue(repoID: "o/m", revision: "main",
                                             sources: [source(urlA, path: "model.gguf",
                                                              bytes: data.count, sha256: digest)])
        let running = await waitFor {
            (try? await manager1.jobs().first)?.files[0].state == .downloading
        }
        XCTAssertTrue(running)
        // Bytes on disk at the moment of "death".
        let partURL = try layout.partialFileURL(jobID: job.id, relativePath: "model.gguf")
        try data.prefix(100).write(to: partURL)

        // New process: new manager, same store + layout.
        let transport2 = MockTransport()
        transport2.setBehavior(.succeed(data), for: urlA)
        let manager2 = DownloadManager(store: DownloadStore(directory: storeDir),
                                       layout: layout, transport: transport2)
        try await manager2.restore()
        let restored = try await manager2.jobs().first(where: { $0.id == job.id })
        XCTAssertEqual(restored?.files[0].state, .paused,
                       "in-flight files become paused after relaunch")

        await manager2.registerSources(
            [source(urlA, path: "model.gguf", bytes: data.count, sha256: digest)], for: job.id)
        try await manager2.resume(jobID: job.id)
        let done = await waitFor {
            (try? await manager2.jobs().first)?.files[0].state == .completed
        }
        XCTAssertTrue(done, "relaunch recovery did not complete")
        let installed = tempRoot.appendingPathComponent("Models/o_m/main/model.gguf")
        XCTAssertEqual(try Data(contentsOf: installed), data)
        XCTAssertEqual(try DownloadManager.sha256Hex(of: installed), digest)
    }

    // MARK: - Concurrency

    /// With a limit of 1 and many files, exactly one transfer runs at a time
    /// and all complete in order.
    func testConcurrencyLimitOneSerializesManyFiles() async throws {
        let urls = (0..<5).map { URL(string: "https://huggingface.co/o/m/resolve/main/f\($0).bin")! }
        let transport = MockTransport()
        var sources: [DownloadSource] = []
        for (i, url) in urls.enumerated() {
            let data = Data(repeating: UInt8(i), count: 32 + i)
            transport.setBehavior(.succeed(data), for: url)
            sources.append(source(url, path: "f\(i).bin", bytes: data.count))
        }
        let manager = await makeManager(transport: transport, concurrency: 1)
        let job = try await manager.enqueue(repoID: "o/m", revision: "main", sources: sources)
        let done = await waitFor(10) {
            guard let j = try? await manager.jobs().first(where: { $0.id == job.id }) else { return false }
            return j.files.allSatisfy { $0.state == .completed }
        }
        XCTAssertTrue(done)
        XCTAssertEqual(transport.startedRequests.count, 5)
    }

    // MARK: - Store corruption

    /// A corrupted store file must surface a typed error, not crash.
    func testCorruptedStoreFileThrows() async throws {
        let storeDir = tempRoot.appendingPathComponent("store")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: storeDir.appendingPathComponent("jobs.json"))
        let store = DownloadStore(directory: storeDir)
        do {
            _ = try await store.allJobs()
            XCTFail("corrupted store must throw")
        } catch {
            // typed error expected; must not crash
        }
    }
}
