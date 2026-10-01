import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LocallyStorage
import LocallyCore

final class ModelInstallServiceTests: XCTestCase {
    private var root: URL!
    private var layout: FilesystemLayout!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("install-tests-\(UUID().uuidString)", isDirectory: true)
        layout = FilesystemLayout(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeManager(transport: MockTransport) -> DownloadManager {
        DownloadManager(
            store: DownloadStore(directory: layout.downloadsRoot.appendingPathComponent("store", isDirectory: true)),
            layout: layout,
            transport: transport,
            clock: .init(sleep: { _ in }))
    }

    private func descriptor() -> ModelDescriptor {
        ModelDescriptor(
            repoID: "bartowski/SmolLM2-135M-Instruct-GGUF",
            name: "SmolLM2-135M-Instruct-GGUF",
            modality: .text,
            quantization: Quantization(bits: 4, scheme: "Q4_K_M"),
            formats: [.gguf],
            totalDownloadSize: 96,
            requiredFiles: [
                RemoteModelFile(path: "SmolLM2-135M-Instruct-Q4_K_M.gguf", size: 80,
                                sha256: String(repeating: "b", count: 64)),
                RemoteModelFile(path: "config.json", size: 16),
            ],
            supportedRuntimes: [.gguf],
            contextLength: 8192)
    }

    // MARK: - Source building

    func testSourcesResolveURLAndSHA() async throws {
        let service = ModelInstallService(downloadManager: makeManager(transport: MockTransport()),
                                          registry: ModelRegistry(root: root))
        let sources = try await service.sources(for: descriptor(), revision: "abc123")
        XCTAssertEqual(sources.count, 2)
        let weights = sources[0]
        XCTAssertEqual(weights.url.absoluteString,
                       "https://huggingface.co/bartowski/SmolLM2-135M-Instruct-GGUF/resolve/abc123/SmolLM2-135M-Instruct-Q4_K_M.gguf")
        XCTAssertEqual(weights.relativePath, "SmolLM2-135M-Instruct-Q4_K_M.gguf")
        XCTAssertEqual(weights.expectedSize, 80)
        XCTAssertEqual(weights.sha256, String(repeating: "b", count: 64))
        let config = sources[1]
        XCTAssertNil(config.sha256)
        XCTAssertEqual(config.url.host, "huggingface.co")
        XCTAssertEqual(config.url.scheme, "https")
    }

    func testSourcesEscapeRevisionAndPathSegments() async throws {
        var d = descriptor()
        d.requiredFiles = [RemoteModelFile(path: "sub dir/my file.gguf", size: 1)]
        let service = ModelInstallService(downloadManager: makeManager(transport: MockTransport()),
                                          registry: ModelRegistry(root: root))
        let sources = try await service.sources(for: d, revision: "refs/pr/7")
        XCTAssertEqual(sources.first?.url.absoluteString,
                       "https://huggingface.co/bartowski/SmolLM2-135M-Instruct-GGUF/resolve/refs%2Fpr%2F7/sub%20dir/my%20file.gguf")
    }

    func testSourcesRejectTraversal() async throws {
        var d = descriptor()
        d.requiredFiles = [RemoteModelFile(path: "../evil.bin", size: 1)]
        let service = ModelInstallService(downloadManager: makeManager(transport: MockTransport()),
                                          registry: ModelRegistry(root: root))
        do {
            _ = try await service.sources(for: d, revision: "main")
            XCTFail("expected traversal rejection")
        } catch let error as LocallyError {
            guard case .pathTraversal = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testSourcesEmptyDescriptorThrows() async throws {
        var d = descriptor()
        d.requiredFiles = []
        let service = ModelInstallService(downloadManager: makeManager(transport: MockTransport()),
                                          registry: ModelRegistry(root: root))
        do {
            _ = try await service.sources(for: d, revision: "main")
            XCTFail("expected failure for empty descriptor")
        } catch let error as LocallyError {
            guard case .downloadFailed = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    // MARK: - Auth header provider

    func testAuthHeaderOnlyForHFHosts() async throws {
        let service = ModelInstallService(downloadManager: makeManager(transport: MockTransport()),
                                          registry: ModelRegistry(root: root),
                                          authHeaderProvider: { "tok123" })
        let hf = URL(string: "https://huggingface.co/org/m/resolve/main/f.gguf")!
        let cdn = URL(string: "https://cdn-lfs.hf.co/xyz")!
        let evil = URL(string: "https://evilhuggingface.co/steal")!
        let other = URL(string: "https://example.com/x")!
        let hfHeader = await service.authorizationHeader(for: hf)
        let cdnHeader = await service.authorizationHeader(for: cdn)
        let evilHeader = await service.authorizationHeader(for: evil)
        let otherHeader = await service.authorizationHeader(for: other)
        XCTAssertEqual(hfHeader, "Bearer tok123")
        XCTAssertEqual(cdnHeader, "Bearer tok123")
        XCTAssertNil(evilHeader)
        XCTAssertNil(otherHeader)
    }

    func testAuthHeaderNilWithoutToken() async throws {
        let service = ModelInstallService(downloadManager: makeManager(transport: MockTransport()),
                                          registry: ModelRegistry(root: root),
                                          authHeaderProvider: { nil })
        let hf = URL(string: "https://huggingface.co/org/m/resolve/main/f.gguf")!
        let header = await service.authorizationHeader(for: hf)
        XCTAssertNil(header)
    }

    // MARK: - End-to-end with mock transport

    func testEndToEndInstallRegistersModel() async throws {
        let weights = Data(repeating: 0xAB, count: 80)
        let configData = Data(repeating: 0x7B, count: 16)
        let transport = MockTransport()
        let weightsURL = URL(string: "https://huggingface.co/bartowski/SmolLM2-135M-Instruct-GGUF/resolve/abc123/SmolLM2-135M-Instruct-Q4_K_M.gguf")!
        let configURL = URL(string: "https://huggingface.co/bartowski/SmolLM2-135M-Instruct-GGUF/resolve/abc123/config.json")!
        transport.setBehavior(.succeed(weights), for: weightsURL)
        transport.setBehavior(.succeed(configData), for: configURL)

        let manager = makeManager(transport: transport)
        let registry = ModelRegistry(root: root)
        try await registry.load()
        let service = ModelInstallService(downloadManager: manager, registry: registry,
                                          authHeaderProvider: { "tok" })

        // sha256 of the 80-byte payload the mock will deliver; install must
        // verify against it. Compute it the same way the manager does.
        var d = descriptor()
        var hasher = StreamingSHA256()
        hasher.update(weights)
        d.requiredFiles[0].sha256 = hasher.finalize()

        let job = try await service.install(descriptor: d, revision: "abc123")
        XCTAssertEqual(job.files.count, 2)

        // Wait for the registry to pick up the completed install.
        let deadline = Date().addingTimeInterval(10)
        var model: InstalledModel?
        while Date() < deadline {
            model = await registry.get(id: "bartowski/SmolLM2-135M-Instruct-GGUF@abc123")
            if model != nil { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let installed = try XCTUnwrap(model, "registry never received the installed model")
        XCTAssertEqual(installed.revision, "abc123")
        XCTAssertEqual(installed.runtime, .gguf)

        // Files actually landed in the model tree.
        let installedWeights = try layout.installedFileURL(
            repoID: d.repoID, revision: "abc123", relativePath: "SmolLM2-135M-Instruct-Q4_K_M.gguf")
        XCTAssertEqual(try Data(contentsOf: installedWeights), weights)
        let installedConfig = try layout.installedFileURL(
            repoID: d.repoID, revision: "abc123", relativePath: "config.json")
        XCTAssertEqual(try Data(contentsOf: installedConfig), configData)
    }

    func testFailedInstallDoesNotRegister() async throws {
        let transport = MockTransport()
        let d = descriptor()
        for file in d.requiredFiles {
            let url = URL(string: "https://huggingface.co/\(d.repoID)/resolve/abc123/\(file.path)")!
            transport.setBehavior(.failStatus(500), for: url)
        }
        let manager = makeManager(transport: transport)
        let registry = ModelRegistry(root: root)
        try await registry.load()
        let service = ModelInstallService(downloadManager: manager, registry: registry)
        _ = try await service.install(descriptor: d, revision: "abc123")

        let deadline = Date().addingTimeInterval(10)
        var finished = false
        while Date() < deadline {
            if let job = try await manager.jobs().first, job.isFinished { finished = true; break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(finished)
        try await Task.sleep(nanoseconds: 1_500_000_000)  // let any watch fire
        let absent = await registry.get(id: "\(d.repoID)@abc123")
        XCTAssertNil(absent)
    }
}
