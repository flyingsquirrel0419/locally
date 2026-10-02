import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import LocallyCore
@testable import LocallyStorage

/// Contract tests for DownloadManager + FoundationURLSessionTransport over a
/// real loopback HTTP server: Range resume appends the suffix to the kept
/// prefix, fresh downloads replace, and the request carries a stable
/// "<jobID>|<fileIndex>" task key. These pin the bugs behind the on-device
/// "download does not work" report: the background transport replaced the
/// part file with only the suffix on resume, and reattached tasks lost
/// their job mapping because the task description never carried it.
final class DownloadTransportContractTests: XCTestCase {
    private var tempRoot: URL!
    private var server: LoopbackHTTPServer?

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let server = try LoopbackHTTPServer()
        server.start()
        self.server = server
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makeManager(transport: DownloadTransport) throws -> DownloadManager {
        let layout = FilesystemLayout(root: tempRoot)
        let store = DownloadStore(directory: tempRoot.appendingPathComponent("store"))
        return DownloadManager(store: store, layout: layout, transport: transport)
    }

    private func waitForJob(_ manager: DownloadManager, id: UUID,
                            timeout: TimeInterval = 30) async -> DownloadJob? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let job = try? await manager.jobs().first(where: { $0.id == id }),
               job.files.allSatisfy({ $0.state == .completed || $0.state == .failed }) {
                return job
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return try? await manager.jobs().first(where: { $0.id == id })
    }

    func testFreshDownloadReplacesStalePartFile() async throws {
        let payload = Data((0..<65_536).map { UInt8($0 % 251) })
        server!.setPlan(.init(payload: payload), for: "/model.bin")
        // Transport level: a plain request with no Range header and no resume
        // data must REPLACE a stale destination, never append onto it.
        let transport = FoundationURLSessionTransport()
        let destination = tempRoot.appendingPathComponent("model.bin.part")
        try Data("stale".utf8).write(to: destination)
        _ = try await transport.start(
            request: URLRequest(url: server!.url(for: "/model.bin")),
            resumeData: nil, destination: destination, taskKey: "test|0")
        var sawFinished = false
        for await (_, event) in transport.events {
            if case .finished(let appending) = event {
                XCTAssertFalse(appending, "a fresh transfer must not append")
                sawFinished = true
                break
            }
            if case .failed(let error, _) = event {
                XCTFail("transfer failed: \(error)")
                break
            }
        }
        XCTAssertTrue(sawFinished)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        let recorded = server!.recordedRequests()
        XCTAssertNil(recorded.first(where: { $0.path == "/model.bin" })?.headers["range"])
    }

    func testRangeResumeAppendsSuffixToPrefix() async throws {
        let payload = Data((0..<131_072).map { UInt8(($0 * 7) % 253) })
        let prefixCount = 40_960
        server!.setPlan(.init(payload: payload), for: "/model.bin")
        // Transport level, real HTTP: write a genuine prefix, then start a
        // resuming request (Range header) whose 206 suffix must be APPENDED
        // to the part file. Regression test for the on-device bug where a
        // resumed transfer replaced the prefix with only the suffix.
        let transport = FoundationURLSessionTransport()
        let destination = tempRoot.appendingPathComponent("model.bin.part")
        try payload.prefix(prefixCount).write(to: destination)
        var request = URLRequest(url: server!.url(for: "/model.bin"))
        request.setValue("bytes=\(prefixCount)-", forHTTPHeaderField: "Range")
        _ = try await transport.start(request: request, resumeData: nil,
                                      destination: destination, taskKey: "test|0")
        var sawFinished = false
        for await (_, event) in transport.events {
            if case .finished(let appending) = event {
                XCTAssertTrue(appending, "a Range transfer must append")
                sawFinished = true
                break
            }
            if case .failed(let error, _) = event {
                XCTFail("transfer failed: \(error)")
                break
            }
        }
        XCTAssertTrue(sawFinished)
        XCTAssertEqual(try Data(contentsOf: destination), payload,
                       "part file must be prefix + suffix, not suffix alone")
    }

    func testStartCarriesJobFileTaskKey() async throws {
        let payload = Data(repeating: 1, count: 1024)
        server!.setPlan(.init(payload: payload), for: "/m")
        let transport = MockTransport()
        transport.setBehavior(.succeed(payload), for: server!.url(for: "/m"))
        let manager = try makeManager(transport: transport)
        let job = try await manager.enqueue(
            repoID: "org/model", revision: "main",
            sources: [DownloadSource(url: server!.url(for: "/m"),
                                     relativePath: "m", expectedSize: Int64(payload.count))])
        let finished = await waitForJob(manager, id: job.id)
        XCTAssertEqual(finished?.files.first?.state, .completed)
        XCTAssertEqual(transport.startedRequests.first?.taskKey,
                       DownloadManager.taskKey(jobID: job.id, fileIndex: 0))
    }

    func testTaskKeyRoundTrip() {
        let jobID = UUID()
        let key = DownloadManager.taskKey(jobID: jobID, fileIndex: 3)
        let parsed = DownloadManager.parseTaskKey(key)
        XCTAssertEqual(parsed?.jobID, jobID)
        XCTAssertEqual(parsed?.fileIndex, 3)
        XCTAssertNil(DownloadManager.parseTaskKey("1"))
        XCTAssertNil(DownloadManager.parseTaskKey("not-a-uuid|0"))
        XCTAssertNil(DownloadManager.parseTaskKey(""))
    }

    func testWiFiOnlyPolicyBlocksStartOnUnknownPath() async throws {
        let payload = Data(repeating: 2, count: 512)
        server!.setPlan(.init(payload: payload), for: "/m")
        let transport = MockTransport()
        let layout = FilesystemLayout(root: tempRoot)
        let store = DownloadStore(directory: tempRoot.appendingPathComponent("store"))
        // Unknown network path with a Wi-Fi-only policy must NOT start.
        let manager = DownloadManager(store: store, layout: layout, transport: transport,
                                      network: NetworkPathProvider(isUsableWiFi: { false }))
        let job = try await manager.enqueue(
            repoID: "org/model", revision: "main",
            sources: [DownloadSource(url: server!.url(for: "/m"),
                                     relativePath: "m", expectedSize: Int64(payload.count))],
            policy: DownloadPolicy(allowsCellular: false))
        try await Task.sleep(nanoseconds: 500_000_000)
        let current = try await manager.jobs().first(where: { $0.id == job.id })
        XCTAssertEqual(current?.files.first?.state, .queued,
                       "Wi-Fi-only job must stay queued when the path is unknown")
        XCTAssertTrue(transport.startedRequests.isEmpty)
        let diagnostics = manager.recentDiagnostics()
        XCTAssertTrue(diagnostics.contains { $0.detail.contains("Wi-Fi") },
                      "diagnostics must explain why the download is waiting")
    }

    func testWiFiOnlyPolicyStartsOnWiFi() async throws {
        let payload = Data(repeating: 3, count: 512)
        server!.setPlan(.init(payload: payload), for: "/m")
        let transport = MockTransport()
        transport.setBehavior(.succeed(payload), for: server!.url(for: "/m"))
        let layout = FilesystemLayout(root: tempRoot)
        let store = DownloadStore(directory: tempRoot.appendingPathComponent("store"))
        let manager = DownloadManager(store: store, layout: layout, transport: transport,
                                      network: NetworkPathProvider(isUsableWiFi: { true }))
        let job = try await manager.enqueue(
            repoID: "org/model", revision: "main",
            sources: [DownloadSource(url: server!.url(for: "/m"),
                                     relativePath: "m", expectedSize: Int64(payload.count))],
            policy: DownloadPolicy(allowsCellular: false))
        let finished = await waitForJob(manager, id: job.id)
        XCTAssertEqual(finished?.files.first?.state, .completed)
    }

    func testDiagnosticsRecordLifecycleAndFailures() async throws {
        let transport = MockTransport()
        let failingURL = server!.url(for: "/gone")
        transport.setBehavior(.failStatus(404), for: failingURL)
        let manager = try makeManager(transport: transport)
        let job = try await manager.enqueue(
            repoID: "org/model", revision: "main",
            sources: [DownloadSource(url: failingURL, relativePath: "m", expectedSize: 10)])
        let finished = await waitForJob(manager, id: job.id)
        XCTAssertEqual(finished?.files.first?.state, .failed)
        let events = manager.recentDiagnostics()
        XCTAssertTrue(events.contains { $0.detail.contains("enqueued") })
        XCTAssertTrue(events.contains { $0.detail.contains("failed") },
                      "failures must appear in diagnostics: \(events.map(\.detail))")
        XCTAssertEqual(finished?.files.first?.failureDetail,
                       events.first { $0.detail.contains("failed") }?.detail
                        .replacingOccurrences(of: "failed m: ", with: ""))
    }
}
