import XCTest
@testable import LocallyStorage
import LocallyCore

/// Week 12 hardening: registry failure paths — delete while idle/loaded,
/// storage accounting, and reconcile against a damaged filesystem.
final class RegistryFailurePathTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("reg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// Controllable loaded-checker: simulates a runtime holding a model.
    private final class StubLoadedChecker: ModelLoadedChecking, @unchecked Sendable {
        let loaded = LockedState<Set<String>>([])
        func isModelLoaded(repoID: String, revision: String) async -> Bool {
            loaded.withLock { $0.contains("\(repoID)@\(revision)") }
        }
        func setLoaded(_ id: String, _ isLoaded: Bool) {
            loaded.withLock { if isLoaded { $0.insert(id) } else { $0.remove(id) } }
        }
    }

    private func descriptor() -> ModelDescriptor {
        ModelDescriptor(repoID: "org/model", name: "model", modality: .text,
                        formats: [.gguf], requiredFiles: [
                            RemoteModelFile(path: "model.gguf", size: 8, sha256: nil),
                        ])
    }

    /// Register a model with real bytes on disk so sizes are truthful.
    private func registerModelWithBytes(_ registry: ModelRegistry, bytes: Int = 8) async throws -> String {
        let layout = FilesystemLayout(root: tempRoot)
        let dir = layout.modelDirectory(repoID: "org/model", revision: "main")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: dir.appendingPathComponent("model.gguf"))
        let model = InstalledModel(repoID: "org/model", revision: "main",
                                   descriptor: descriptor(), sizeOnDisk: Int64(bytes))
        try await registry.register(model)
        return model.id
    }

    /// Delete while idle: files, record, and the per-model metadata are
    /// gone; the storage summary drops back to zero.
    func testDeleteWhileIdleRemovesEverything() async throws {
        let registry = ModelRegistry(root: tempRoot)
        try await registry.load()
        let id = try await registerModelWithBytes(registry, bytes: 128)

        let before = registry.storageSummary()
        // The directory also holds the per-model metadata.json, so the total
        // is the payload bytes plus that sidecar file.
        let metadataBytes = (try? Data(contentsOf: FilesystemLayout(root: tempRoot)
            .metadataURL(repoID: "org/model", revision: "main")).count) ?? 0
        XCTAssertEqual(before.totalModelBytes, 128 + Int64(metadataBytes))
        XCTAssertEqual(before.perModel[id], 128 + Int64(metadataBytes))

        try await registry.delete(id: id)

        XCTAssertNil(registry.get(id: id))
        XCTAssertTrue(registry.list().isEmpty)
        let after = registry.storageSummary()
        XCTAssertEqual(after.totalModelBytes, 0)
        XCTAssertNil(after.perModel[id])
        let layout = FilesystemLayout(root: tempRoot)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.modelDirectory(repoID: "org/model", revision: "main").path))
        // The empty org_model folder is cleaned up too.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.modelsRoot.appendingPathComponent("org_model").path))
        // Persisted: a fresh registry on the same root sees nothing.
        let reread = ModelRegistry(root: tempRoot)
        try await reread.load()
        XCTAssertTrue(reread.list().isEmpty)
    }

    /// Delete while a runtime holds the model must be refused, and neither
    /// the record nor the files may be touched.
    func testDeleteWhileLoadedIsRefused() async throws {
        let checker = StubLoadedChecker()
        let registry = ModelRegistry(root: tempRoot, loadedChecker: checker)
        try await registry.load()
        let id = try await registerModelWithBytes(registry)
        checker.setLoaded(id, true)

        do {
            try await registry.delete(id: id)
            XCTFail("delete of a loaded model must throw")
        } catch let error as ModelRegistry.RegistryError {
            guard case .modelLoaded(let refused) = error else {
                return XCTFail("expected modelLoaded, got \(error)")
            }
            XCTAssertEqual(refused, id)
        }
        XCTAssertNotNil(registry.get(id: id))
        let layout = FilesystemLayout(root: tempRoot)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.modelDirectory(repoID: "org/model", revision: "main")
                .appendingPathComponent("model.gguf").path))

        // After unload the delete succeeds.
        checker.setLoaded(id, false)
        try await registry.delete(id: id)
        XCTAssertNil(registry.get(id: id))
    }

    /// Deleting an unknown id is a typed notFound, never a crash.
    func testDeleteUnknownIDThrowsNotFound() async throws {
        let registry = ModelRegistry(root: tempRoot)
        try await registry.load()
        do {
            try await registry.delete(id: "nobody/home@main")
            XCTFail("expected notFound")
        } catch let error as ModelRegistry.RegistryError {
            guard case .notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
    }

    /// Reconcile after someone deleted the files behind our back: the record
    /// is flagged missing (not silently dropped) and storage summary is zero.
    func testReconcileFlagsMissingFiles() async throws {
        let registry = ModelRegistry(root: tempRoot)
        try await registry.load()
        let id = try await registerModelWithBytes(registry)

        let layout = FilesystemLayout(root: tempRoot)
        try FileManager.default.removeItem(
            at: layout.modelDirectory(repoID: "org/model", revision: "main"))

        let report = try await registry.reconcile()
        XCTAssertEqual(report.missingFileIDs, [id])
        XCTAssertTrue(registry.get(id: id)?.hasMissingFiles == true)
        XCTAssertEqual(registry.storageSummary().totalModelBytes, 0)
    }

    /// An orphan directory (files on disk, no record) is reported and left
    /// alone — removing it is an explicit user action.
    func testReconcileReportsOrphanWithoutDeleting() async throws {
        let registry = ModelRegistry(root: tempRoot)
        try await registry.load()
        let layout = FilesystemLayout(root: tempRoot)
        let orphan = layout.modelDirectory(repoID: "ghost/model", revision: "main")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 16).write(to: orphan.appendingPathComponent("weights.gguf"))

        let report = try await registry.reconcile()
        XCTAssertEqual(report.orphanDirectories, ["ghost_model/main"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: orphan.appendingPathComponent("weights.gguf").path),
            "reconcile must not delete orphan data")
    }

    /// A corrupted registry.json must surface a typed error on load.
    func testCorruptedRegistryFileThrowsOnLoad() async throws {
        try Data("{ not json".utf8).write(to: tempRoot.appendingPathComponent("registry.json"))
        let registry = ModelRegistry(root: tempRoot)
        do {
            try await registry.load()
            XCTFail("corrupted registry must throw")
        } catch {
            // expected: DecodingError; must not crash
        }
    }
}
