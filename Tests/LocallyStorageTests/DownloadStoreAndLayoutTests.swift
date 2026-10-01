import XCTest
@testable import LocallyStorage
import LocallyCore

final class DownloadStoreTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makeJob(repoID: String = "org/model") -> DownloadJob {
        DownloadJob(modelRepoID: repoID, revision: "main",
                    files: [DownloadFileTask(relativePath: "config.json",
                                             expectedSize: 100, sha256: nil)])
    }

    func testRoundTripPersistence() async throws {
        let store = DownloadStore(directory: tempRoot)
        let job = makeJob()
        try await store.upsert(job)
        // Fresh actor instance reads the same file.
        let reopened = DownloadStore(directory: tempRoot)
        let jobs = try await reopened.allJobs()
        XCTAssertEqual(jobs, [job])
    }

    func testUpsertUpdatesExisting() async throws {
        let store = DownloadStore(directory: tempRoot)
        var job = makeJob()
        try await store.upsert(job)
        job.files[0].bytesReceived = 42
        try await store.upsert(job)
        let fetched = try await store.job(id: job.id)
        XCTAssertEqual(fetched?.files[0].bytesReceived, 42)
        let all = try await store.allJobs()
        XCTAssertEqual(all.count, 1)
    }

    func testRemove() async throws {
        let store = DownloadStore(directory: tempRoot)
        let job = makeJob()
        try await store.upsert(job)
        try await store.remove(id: job.id)
        let all = try await store.allJobs()
        XCTAssertEqual(all, [])
    }

    func testResumeDataIsNotInlineInJSON() async throws {
        let store = DownloadStore(directory: tempRoot)
        var job = makeJob()
        job.files[0].resumeDataFile = "0.resume"
        try await store.upsert(job)
        let raw = try String(contentsOf: tempRoot.appendingPathComponent("jobs.json"), encoding: .utf8)
        XCTAssertTrue(raw.contains("0.resume"))
        XCTAssertFalse(raw.contains("resumeData\":\""))  // no inline blob field
    }
}

final class FilesystemLayoutTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testPartialAndInstalledPathsAreSeparate() throws {
        let layout = FilesystemLayout(root: tempRoot)
        let jobID = UUID()
        let part = try layout.partialFileURL(jobID: jobID, relativePath: "weights/model.bin")
        XCTAssertTrue(part.path.contains("/Downloads/partial/\(jobID.uuidString)/"))
        XCTAssertTrue(part.path.hasSuffix(".part"))
        let installed = try layout.installedFileURL(repoID: "org/model", revision: "main",
                                                    relativePath: "weights/model.bin")
        XCTAssertTrue(installed.path.contains("/Models/org_model/main/weights/model.bin"))
        XCTAssertFalse(installed.path.contains("/Downloads/"))
    }

    func testInstallIsAtomicMoveAndCleansPart() throws {
        let layout = FilesystemLayout(root: tempRoot)
        let jobID = UUID()
        try layout.createDirectories(for: jobID)
        let part = try layout.partialFileURL(jobID: jobID, relativePath: "config.json")
        try FileManager.default.createDirectory(at: part.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: part)
        let installed = try layout.install(jobID: jobID, relativePath: "config.json",
                                           repoID: "org/model", revision: "main")
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
        XCTAssertEqual(try Data(contentsOf: installed), Data("hello".utf8))
    }

    func testRemoveJobArtifacts() throws {
        let layout = FilesystemLayout(root: tempRoot)
        let jobID = UUID()
        try layout.createDirectories(for: jobID)
        let part = try layout.partialFileURL(jobID: jobID, relativePath: "x.bin")
        try Data("x".utf8).write(to: part)
        try Data("r".utf8).write(to: layout.resumeDataURL(jobID: jobID, fileIndex: 0))
        layout.removeJobArtifacts(jobID: jobID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.partialDirectory(jobID: jobID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.resumeDirectory(jobID: jobID).path))
    }

    func testTraversalRejectedInPartialPath() {
        let layout = FilesystemLayout(root: tempRoot)
        XCTAssertThrowsError(try layout.partialFileURL(jobID: UUID(), relativePath: "../evil"))
        XCTAssertThrowsError(try layout.installedFileURL(repoID: "o/m", revision: "main",
                                                         relativePath: ".."))
    }
}
