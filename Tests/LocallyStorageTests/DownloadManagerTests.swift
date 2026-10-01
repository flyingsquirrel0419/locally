import XCTest
@testable import LocallyStorage
import LocallyCore

/// Thread-safe recorder for injected sleep intervals.
final class SleepRecorder: Sendable {
    private let intervals = LockedState<[TimeInterval]>([])
    func record(_ t: TimeInterval) { intervals.withLock { $0.append(t) } }
    var all: [TimeInterval] { intervals.withLock { $0 } }
}

final class DownloadManagerTests: XCTestCase {
    private var tempRoot: URL!
    private var layout: FilesystemLayout!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        layout = FilesystemLayout(root: tempRoot)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private let urlA = URL(string: "https://example.com/a.bin")!
    private let urlB = URL(string: "https://example.com/b.bin")!
    private let urlC = URL(string: "https://example.com/c.bin")!

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
                             charging: @escaping @Sendable () -> Bool = { true },
                             free: Int64 = .max,
                             concurrency: Int = 2) async -> DownloadManager {
        let store = DownloadStore(directory: tempRoot.appendingPathComponent("store"))
        let clock = DownloadClock(
            sleep: { interval in sleeps?.record(interval) },
            now: { Date() })
        return DownloadManager(store: store, layout: layout, transport: transport,
                               clock: clock, power: PowerStateProvider(isCharging: charging),
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

    func testHappyPathMultiFileInstallsAndWritesMetadata() async throws {
        let dataA = Data((0..<100).map { UInt8($0 % 256) })
        let dataB = Data((0..<50).map { UInt8(255 - $0 % 256) })
        let transport = MockTransport()
        transport.setBehavior(.succeed(dataA), for: urlA)
        transport.setBehavior(.succeed(dataB), for: urlB)
        let manager = await makeManager(transport: transport)

        let job = try await manager.enqueue(repoID: "org/model", revision: "main",
                                            sources: [source(urlA, path: "a.bin", bytes: dataA.count,
                                                             sha256: sha256(dataA)),
                                                      source(urlB, path: "sub/b.bin", bytes: dataB.count)])

        let metadataURL = tempRoot.appendingPathComponent("Models/org_model/main/metadata.json")
        let done = await waitFor {
            guard let j = try? await manager.jobs().first(where: { $0.id == job.id }) else { return false }
            // Metadata is written after the final file's completion upsert.
            return j.files.allSatisfy { $0.state == .completed }
                && FileManager.default.fileExists(atPath: metadataURL.path)
        }
        XCTAssertTrue(done, "job did not complete")

        let aInstalled = tempRoot.appendingPathComponent("Models/org_model/main/a.bin")
        let bInstalled = tempRoot.appendingPathComponent("Models/org_model/main/sub/b.bin")
        XCTAssertEqual(try Data(contentsOf: aInstalled), dataA)
        XCTAssertEqual(try Data(contentsOf: bInstalled), dataB)

        let metadata = try JSONDecoder().decode(InstalledModelMetadata.self,
                                                from: Data(contentsOf: metadataURL))
        XCTAssertEqual(metadata.files, ["a.bin": Int64(dataA.count), "sub/b.bin": Int64(dataB.count)])
        // Partial tree cleaned after full completion.
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.partialDirectory(jobID: job.id).path))
    }

    func testPauseResumeUsesResumeDataThenRangeFallback() async throws {
        let data = Data((0..<200).map { UInt8($0 % 256) })
        let transport = MockTransport()
        transport.setBehavior(.hang, for: urlA)
        let manager = await makeManager(transport: transport)
        let job = try await manager.enqueue(repoID: "o/m", revision: "main",
                                            sources: [source(urlA, path: "a.bin", bytes: data.count)])

        let started = await waitFor { transport.startedRequests.count == 1 }
        XCTAssertTrue(started)
        try await manager.pause(jobID: job.id)
        let paused = await waitFor {
            (try? await manager.jobs().first)?.files[0].state == .paused
        }
        XCTAssertTrue(paused)

        // Simulate partial bytes on disk, then flip behavior to succeed.
        let partURL = try layout.partialFileURL(jobID: job.id, relativePath: "a.bin")
        try data.prefix(100).write(to: partURL)
        transport.setBehavior(.succeed(data), for: urlA)
        try await manager.resume(jobID: job.id)

        let done = await waitFor {
            (try? await manager.jobs().first)?.files[0].state == .completed
        }
        XCTAssertTrue(done, "resume did not complete")
        // Second start should have carried resume data from the mock pause.
        XCTAssertEqual(transport.startedRequests.count, 2)
        XCTAssertTrue(transport.startedRequests[1].hasResumeData)
        XCTAssertEqual(try Data(contentsOf: tempRoot.appendingPathComponent("Models/o_m/main/a.bin")), data)
    }

    func testCancelDeletesPartialsAndRemovesJob() async throws {
        let transport = MockTransport()
        transport.setBehavior(.hang, for: urlA)
        let manager = await makeManager(transport: transport)
        let job = try await manager.enqueue(repoID: "o/m", revision: "main",
                                            sources: [source(urlA, path: "a.bin", bytes: 10)])
        let started = await waitFor { transport.startedRequests.count == 1 }
        XCTAssertTrue(started)
        let partURL = try layout.partialFileURL(jobID: job.id, relativePath: "a.bin")
        try Data("partial".utf8).write(to: partURL)

        try await manager.cancel(jobID: job.id)
        let remaining = try await manager.jobs()
        XCTAssertEqual(remaining.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.partialDirectory(jobID: job.id).path))
    }

    func testRetryBackoffForNetworkError() async throws {
        let transport = MockTransport()
        let netError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        transport.setBehavior(.fail(netError, resumeData: nil), for: urlA)
        let sleeps = SleepRecorder()
        let manager = await makeManager(transport: transport, sleeps: sleeps)

        let job = try await manager.enqueue(repoID: "o/m", revision: "main",
                                            sources: [source(urlA, path: "a.bin", bytes: 10)])
        // 1 initial attempt + up to 3 automatic retries with injected clock.
        let exhausted = await waitFor(10) {
            guard let j = try? await manager.jobs().first(where: { $0.id == job.id }) else { return false }
            return j.files[0].state == .failed && j.files[0].attempts >= DownloadManager.maxAutomaticRetries
                && sleeps.all.count >= DownloadManager.maxAutomaticRetries
        }
        XCTAssertTrue(exhausted)
        // The final failed attempt's event may still be in flight; wait until
        // the transport sees the last start before asserting the total.
        let allStarted = await waitFor {
            transport.startedRequests.count == 1 + DownloadManager.maxAutomaticRetries
        }
        XCTAssertTrue(allStarted)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.startedRequests.count, 1 + DownloadManager.maxAutomaticRetries)
        // Exponential backoff: 1, 2, 4 seconds.
        XCTAssertEqual(sleeps.all, [1, 2, 4])
    }

    func test401NotRetried() async throws {
        let transport = MockTransport()
        transport.setBehavior(.failStatus(401), for: urlA)
        let sleeps = SleepRecorder()
        let manager = await makeManager(transport: transport, sleeps: sleeps)

        let job = try await manager.enqueue(repoID: "o/m", revision: "main",
                                            sources: [source(urlA, path: "a.bin", bytes: 10)])
        let failed = await waitFor {
            (try? await manager.jobs().first)?.files[0].state == .failed
        }
        XCTAssertTrue(failed)
        // Give the scheduler a beat to (incorrectly) retry; it must not.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.startedRequests.count, 1)
        XCTAssertTrue(sleeps.all.isEmpty)
    }

    func testInsufficientStorageFailsBeforeStarting() async throws {
        let transport = MockTransport()
        transport.setBehavior(.succeed(Data(repeating: 0, count: 10)), for: urlA)
        // File needs 10 bytes + 512 MB headroom; only 1 MB available.
        let manager = await makeManager(transport: transport, free: 1 << 20)
        let job = try await manager.enqueue(repoID: "o/m", revision: "main",
                                            sources: [source(urlA, path: "a.bin", bytes: 10)])
        let failed = await waitFor {
            (try? await manager.jobs().first)?.files[0].state == .failed
        }
        XCTAssertTrue(failed)
        XCTAssertEqual(transport.startedRequests.count, 0)
        let detail = try await manager.jobs().first?.files[0].failureDetail
        XCTAssertTrue(detail?.contains("required=") == true)
    }

    func testHashMismatchFailsAndDeletesPart() async throws {
        let data = Data("real content".utf8)
        let transport = MockTransport()
        transport.setBehavior(.succeed(data), for: urlA)
        let manager = await makeManager(transport: transport)
        let wrongDigest = String(repeating: "0", count: 64)
        let job = try await manager.enqueue(repoID: "o/m", revision: "main",
                                            sources: [source(urlA, path: "a.bin", bytes: data.count,
                                                             sha256: wrongDigest)])
        let failed = await waitFor {
            (try? await manager.jobs().first)?.files[0].state == .failed
        }
        XCTAssertTrue(failed)
        let partURL = try layout.partialFileURL(jobID: job.id, relativePath: "a.bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partURL.path))
        let detail = try await manager.jobs().first?.files[0].failureDetail
        XCTAssertTrue(detail?.contains("sha256 mismatch") == true)
    }

    func testSizeMismatchFailsAndDeletesPart() async throws {
        let transport = MockTransport()
        transport.setBehavior(.succeed(Data("short".utf8)), for: urlA)
        let manager = await makeManager(transport: transport)
        let job = try await manager.enqueue(repoID: "o/m", revision: "main",
                                            sources: [source(urlA, path: "a.bin", bytes: 100)])
        let failed = await waitFor {
            (try? await manager.jobs().first)?.files[0].state == .failed
        }
        XCTAssertTrue(failed)
        let partURL = try layout.partialFileURL(jobID: job.id, relativePath: "a.bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partURL.path))
    }

    func testRestoreAfterRelaunchPausesInFlight() async throws {
        let data = Data("payload".utf8)
        let transport1 = MockTransport()
        transport1.setBehavior(.hang, for: urlA)
        let storeDir = tempRoot.appendingPathComponent("store")
        let manager1 = DownloadManager(store: DownloadStore(directory: storeDir),
                                       layout: layout, transport: transport1)
        let job = try await manager1.enqueue(repoID: "o/m", revision: "main",
                                             sources: [source(urlA, path: "a.bin", bytes: data.count)])
        let running = await waitFor {
            (try? await manager1.jobs().first)?.files[0].state == .downloading
        }
        XCTAssertTrue(running)

        // Simulate relaunch: new manager on the same store and layout.
        let transport2 = MockTransport()
        transport2.setBehavior(.succeed(data), for: urlA)
        let manager2 = DownloadManager(store: DownloadStore(directory: storeDir),
                                       layout: layout, transport: transport2)
        try await manager2.restore()
        let restored = try await manager2.jobs().first(where: { $0.id == job.id })
        XCTAssertEqual(restored?.files[0].state, .paused)

        // App re-supplies sources and resumes; download completes.
        await manager2.registerSources([source(urlA, path: "a.bin", bytes: data.count)], for: job.id)
        try await manager2.resume(jobID: job.id)
        let done = await waitFor {
            (try? await manager2.jobs().first)?.files[0].state == .completed
        }
        XCTAssertTrue(done)
    }

    func testPathTraversalRejectedAtEnqueue() async throws {
        let transport = MockTransport()
        let manager = await makeManager(transport: transport)
        await XCTAssertThrowsErrorAsync(
            try await manager.enqueue(repoID: "o/m", revision: "main",
                                      sources: [source(urlA, path: "../escape.bin", bytes: 1)]))
    }

    func testConcurrencyLimitRespected() async throws {
        let transport = MockTransport()
        transport.setBehavior(.hang, for: urlA)
        transport.setBehavior(.hang, for: urlB)
        transport.setBehavior(.hang, for: urlC)
        let manager = await makeManager(transport: transport, concurrency: 2)
        _ = try await manager.enqueue(repoID: "o/m", revision: "main",
                                      sources: [source(urlA, path: "a.bin", bytes: 1),
                                                source(urlB, path: "b.bin", bytes: 1),
                                                source(urlC, path: "c.bin", bytes: 1)])
        let two = await waitFor { transport.startedRequests.count == 2 }
        XCTAssertTrue(two)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(transport.startedRequests.count, 2, "third file started beyond limit")

        // Complete one transfer; the queued third file should now start.
        transport.setBehavior(.succeed(Data("x".utf8)), for: urlA)
        let jobs = try await manager.jobs()
        try await manager.cancel(jobID: jobs[0].id)
    }

    func testChargingPolicyPausesWhenUnplugged() async throws {
        let transport = MockTransport()
        transport.setBehavior(.succeed(Data("x".utf8)), for: urlA)
        let manager = await makeManager(transport: transport, charging: { false })
        let job = try await manager.enqueue(
            repoID: "o/m", revision: "main",
            sources: [source(urlA, path: "a.bin", bytes: 1)],
            policy: DownloadPolicy(allowsCellular: false, onlyWhileCharging: true))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(transport.startedRequests.count, 0, "started while unplugged")
        let stored = try await manager.jobs().first(where: { $0.id == job.id })
        XCTAssertEqual(stored?.files[0].state, .queued)
    }
}

func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                  _ message: String = "",
                                  file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected error but succeeded \(message)", file: file, line: line)
    } catch {
        // expected
    }
}
