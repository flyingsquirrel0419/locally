import XCTest
@testable import LocallyStorage
import LocallyCore

final class ModelRegistryTests: XCTestCase {
    private var root: URL!
    private var layout: FilesystemLayout!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-tests-\(UUID().uuidString)", isDirectory: true)
        layout = FilesystemLayout(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func descriptor(repoID: String = "org/name") -> ModelDescriptor {
        ModelDescriptor(
            repoID: repoID, name: "name", modality: .text,
            quantization: Quantization(bits: 4, scheme: "Q4_K_M"),
            formats: [.gguf],
            totalDownloadSize: 100,
            requiredFiles: [RemoteModelFile(path: "model.gguf", size: 100,
                                            sha256: String(repeating: "a", count: 64))],
            supportedRuntimes: [.gguf],
            contextLength: 4096)
    }

    private func installFiles(repoID: String = "org/name", revision: String = "abc123",
                              files: [String: Data] = ["model.gguf": Data(repeating: 0x1, count: 100)]) throws {
        for (path, data) in files {
            let url = try layout.installedFileURL(repoID: repoID, revision: revision, relativePath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }

    // MARK: - Persistence

    func testRegisterPersistReload() async throws {
        let registry = ModelRegistry(root: root)
        try await registry.load()
        try installFiles()
        try await registry.register(InstalledModel(repoID: "org/name", revision: "abc123",
                                                   descriptor: descriptor(), sizeOnDisk: 100))
        XCTAssertEqual(registry.list().count, 1)

        let reloaded = ModelRegistry(root: root)
        try await reloaded.load()
        let fetched = reloaded.get(id: "org/name@abc123")
        let model = try XCTUnwrap(fetched)
        XCTAssertEqual(model.repoID, "org/name")
        XCTAssertEqual(model.revision, "abc123")
        XCTAssertEqual(model.quantization?.scheme, "Q4_K_M")
        XCTAssertEqual(model.runtime, .gguf)
        // Recomputed from disk, not blindly trusted.
        XCTAssertEqual(model.sizeOnDisk, 100)
    }

    func testRegistryJSONLivesAtRootAndMetadataPerModel() async throws {
        let registry = ModelRegistry(root: root)
        try await registry.load()
        try installFiles()
        try await registry.register(InstalledModel(repoID: "org/name", revision: "abc123",
                                                   descriptor: descriptor(), sizeOnDisk: 100))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("registry.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.metadataURL(repoID: "org/name", revision: "abc123").path))
    }

    func testLoadMissingFileIsEmpty() async throws {
        let registry = ModelRegistry(root: root)
        try await registry.load()
        XCTAssertTrue(registry.list().isEmpty)
    }

    // MARK: - Usage & settings

    func testMarkUsedUpdatesRecents() async throws {
        final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_000) }
        let clock = Clock()
        let registry = ModelRegistry(root: root, now: { clock.t })
        try await registry.load()
        try installFiles(repoID: "org/name", revision: "r1")
        try await registry.register(InstalledModel(repoID: "org/name", revision: "r1",
                                                   descriptor: descriptor(), sizeOnDisk: 100))
        XCTAssertTrue(registry.recentModels().isEmpty)
        clock.t = Date(timeIntervalSince1970: 2_000)
        try await registry.markUsed(id: "org/name@r1")
        let recents = registry.recentModels()
        XCTAssertEqual(recents.first?.lastUsedAt, clock.t)
        XCTAssertEqual(recents.first?.id, "org/name@r1")
    }

    func testUpdateSettingsClampsContextAndSetsRuntime() async throws {
        let registry = ModelRegistry(root: root)
        try await registry.load()
        try installFiles(repoID: "org/name", revision: "r1")
        try await registry.register(InstalledModel(repoID: "org/name", revision: "r1",
                                                   descriptor: descriptor(), sizeOnDisk: 100))
        try await registry.updateSettings(id: "org/name@r1", context: .some(999_999))
        var model = try XCTUnwrap(registry.get(id: "org/name@r1"))
        XCTAssertEqual(model.contextOverride, 4096)  // clamped to descriptor max
        try await registry.updateSettings(id: "org/name@r1", context: .some(2048))
        model = try XCTUnwrap(registry.get(id: "org/name@r1"))
        XCTAssertEqual(model.contextOverride, 2048)
    }

    // MARK: - Delete

    func testDeleteRefusesLoadedModel() async throws {
        struct Loaded: ModelLoadedChecking {
            func isModelLoaded(repoID: String, revision: String) async -> Bool { true }
        }
        let registry = ModelRegistry(root: root, loadedChecker: Loaded())
        try await registry.load()
        try installFiles(repoID: "org/name", revision: "r1")
        try await registry.register(InstalledModel(repoID: "org/name", revision: "r1",
                                                   descriptor: descriptor(), sizeOnDisk: 100))
        do {
            try await registry.delete(id: "org/name@r1")
            XCTFail("expected refusal")
        } catch let error as ModelRegistry.RegistryError {
            guard case .modelLoaded = error else { return XCTFail("wrong error: \(error)") }
        }
        // Record and files survive.
        let surviving = registry.get(id: "org/name@r1")
        XCTAssertNotNil(surviving)
        let dir = layout.modelDirectory(repoID: "org/name", revision: "r1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    func testDeleteRemovesFilesAndRecord() async throws {
        let registry = ModelRegistry(root: root)
        try await registry.load()
        try installFiles(repoID: "org/name", revision: "r1")
        try installFiles(repoID: "org/name", revision: "r2")
        try await registry.register(InstalledModel(repoID: "org/name", revision: "r1",
                                                   descriptor: descriptor(), sizeOnDisk: 100))
        try await registry.register(InstalledModel(repoID: "org/name", revision: "r2",
                                                   descriptor: descriptor(), sizeOnDisk: 100))
        try await registry.delete(id: "org/name@r1")
        XCTAssertNil(registry.get(id: "org/name@r1"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.modelDirectory(repoID: "org/name", revision: "r1").path))
        // Other revision untouched; org folder kept.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.modelDirectory(repoID: "org/name", revision: "r2").path))
        // Delete the last revision: org folder goes too.
        try await registry.delete(id: "org/name@r2")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.modelsRoot.appendingPathComponent("org_name").path))
    }

    // MARK: - Reconcile

    func testReconcileFlagsMissingFiles() async throws {
        let registry = ModelRegistry(root: root)
        try await registry.load()
        try installFiles(repoID: "org/name", revision: "r1")
        try await registry.register(InstalledModel(repoID: "org/name", revision: "r1",
                                                   descriptor: descriptor(), sizeOnDisk: 100))
        // Wipe the files behind the registry's back.
        try FileManager.default.removeItem(at: layout.modelDirectory(repoID: "org/name", revision: "r1"))
        let report = try await registry.reconcile()
        XCTAssertEqual(report.missingFileIDs, ["org/name@r1"])
        XCTAssertTrue(report.orphanDirectories.isEmpty)
        let model = try XCTUnwrap(registry.get(id: "org/name@r1"))
        XCTAssertTrue(model.hasMissingFiles)
        // Record survives reconcile; deletion is a user decision.
    }

    func testReconcileReportsOrphansWithoutDeleting() async throws {
        let registry = ModelRegistry(root: root)
        try await registry.load()
        // Unregistered folder in the model tree.
        let orphan = layout.modelDirectory(repoID: "some/one", revision: "zzz")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: orphan.appendingPathComponent("model.gguf"))
        let report = try await registry.reconcile()
        XCTAssertEqual(report.orphanDirectories, ["some_one/zzz"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testReconcileClearsFlagWhenFilesReturn() async throws {
        let registry = ModelRegistry(root: root)
        try await registry.load()
        try installFiles(repoID: "org/name", revision: "r1")
        try await registry.register(InstalledModel(repoID: "org/name", revision: "r1",
                                                   descriptor: descriptor(), sizeOnDisk: 100))
        try FileManager.default.removeItem(at: layout.modelDirectory(repoID: "org/name", revision: "r1"))
        _ = try await registry.reconcile()
        try installFiles(repoID: "org/name", revision: "r1")
        let report = try await registry.reconcile()
        XCTAssertTrue(report.missingFileIDs.isEmpty)
        XCTAssertFalse(try XCTUnwrap(registry.get(id: "org/name@r1")).hasMissingFiles)
    }

    // MARK: - Storage summary

    func testStorageSummary() async throws {
        let registry = ModelRegistry(root: root)
        try await registry.load()
        try installFiles(repoID: "org/name", revision: "r1",
                         files: ["model.gguf": Data(repeating: 0x1, count: 100),
                                 "config.json": Data(repeating: 0x2, count: 20)])
        try await registry.register(InstalledModel(repoID: "org/name", revision: "r1",
                                                   descriptor: descriptor(), sizeOnDisk: 0))
        // Something in the download cache.
        let partial = layout.downloadsRoot.appendingPathComponent("partial/x", isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data(repeating: 0x3, count: 50).write(to: partial.appendingPathComponent("f.part"))

        let summary = registry.storageSummary()
        // metadata.json (repoID + revision + file map + timestamp) is written
        // next to the payload on register; its exact size is an implementation
        // detail, so assert bounds rather than a magic number.
        let modelBytes = try XCTUnwrap(summary.perModel["org/name@r1"])
        XCTAssertGreaterThanOrEqual(modelBytes, 120)
        XCTAssertLessThan(modelBytes, 120 + 512)
        XCTAssertEqual(summary.totalModelBytes, modelBytes)
        XCTAssertEqual(summary.downloadCacheBytes, 50)
    }

    // MARK: - Benchmarks

    func testRecordBenchmarkPersists() async throws {
        let registry = ModelRegistry(root: root)
        try await registry.load()
        try installFiles(repoID: "org/name", revision: "r1")
        try await registry.register(InstalledModel(repoID: "org/name", revision: "r1",
                                                   descriptor: descriptor(), sizeOnDisk: 100))
        let sample = InferenceMetadata(loadTime: 1.2, ttft: 0.3, tokensPerSecond: 42.5,
                                       generatedTokens: 128, peakMemoryBytes: 300_000_000)
        try await registry.recordBenchmark(id: "org/name@r1", sample: sample)
        let reloaded = ModelRegistry(root: root)
        try await reloaded.load()
        let model = try XCTUnwrap(reloaded.get(id: "org/name@r1"))
        XCTAssertEqual(model.benchmarks.count, 1)
        XCTAssertEqual(model.benchmarks.first?.tokensPerSecond, 42.5)
    }
}
