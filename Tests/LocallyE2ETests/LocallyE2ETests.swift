import XCTest
import Foundation
@testable import LocallyCore
@testable import LocallyHF
@testable import LocallyDevice
@testable import LocallyCompatibility
@testable import LocallyStorage
@testable import LocallyRuntime

/// Week 12 live end-to-end: parse a Hugging Face URL → analyze →
/// compatibility → download → simulate relaunch → load → chat → benchmark →
/// unload → delete. Gated on `LOCALLY_LIVE_E2E=1` because it needs the
/// network and a linked llama.cpp.
///
/// Each stage prints its timing so a human can see the flow actually ran
/// end to end.
final class LocallyE2ETests: XCTestCase {

    private static let repoURL = "https://huggingface.co/bartowski/SmolLM2-135M-Instruct-GGUF"
    private static let repoID = "bartowski/SmolLM2-135M-Instruct-GGUF"

    private var tempRoot: URL!

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LOCALLY_LIVE_E2E"] == "1",
                          "set LOCALLY_LIVE_E2E=1 to run the live end-to-end flow")
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    private func stage<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
        let start = Date()
        print("[E2E] ▶ \(name)")
        let value = try await body()
        let elapsed = String(format: "%.2f", Date().timeIntervalSince(start))
        print("[E2E] ✔ \(name) (\(elapsed)s)")
        return value
    }

    func testFullUserFlow() async throws {
        let layout = FilesystemLayout(root: tempRoot)

        // MARK: 1. Parse the URL the user pasted.
        let reference = try await stage("parse URL") {
            try HFRepoReference(parsing: Self.repoURL)
        }
        XCTAssertEqual(reference.repoID.description, Self.repoID)

        // MARK: 2. Analyze the repository through the live HF API.
        let hfClient = HFClient()
        let analyzer = RepositoryAnalyzer()
        let descriptor = try await stage("HF analyze") {
            try await analyzer.analyze(reference, client: hfClient)
        }
        XCTAssertEqual(descriptor.repoID, Self.repoID)
        XCTAssertTrue(descriptor.formats.contains(.gguf),
                      "SmolLM2 GGUF repo must surface the GGUF format")
        XCTAssertFalse(descriptor.requiredFiles.isEmpty,
                       "required files must be non-empty")
        print("[E2E]   descriptor: modality=\(descriptor.modality) "
              + "params=\(descriptor.parameterCount ?? -1) "
              + "quant=\(descriptor.quantization?.scheme ?? "?") "
              + "ctx=\(descriptor.contextLength ?? -1) "
              + "files=\(descriptor.requiredFiles.map(\.path))")

        // MARK: 3. Profile the device and evaluate compatibility.
        let profile = await stage("device profile") {
            await SystemDeviceProfiler().profile()
        }
        let engine = CompatibilityEngine()
        let initialReport = await stage("compatibility report (estimate)") {
            engine.evaluate(descriptor: descriptor, device: profile)
        }
        print("[E2E]   initial rating=\(initialReport.rating) "
              + "speed=\(initialReport.speed) "
              + "recommendedRuntime=\(String(describing: initialReport.recommendedRuntime)) "
              + "blockers=\(initialReport.blockers)")
        XCTAssertNotEqual(initialReport.rating, .unsupported,
                          "135M GGUF must be usable on any Linux dev box")
        XCTAssertEqual(initialReport.recommendedRuntime, .gguf)

        // MARK: 4. Install (download) into a temp root.
        // Linux corelibs URLSession serializes concurrent downloads
        // unpredictably (observed stalls with >1 in-flight), so the E2E
        // deliberately runs one file at a time.
        let store = DownloadStore(directory: tempRoot.appendingPathComponent("Downloads"))
        let registry = ModelRegistry(root: tempRoot)
        try await registry.load()
        let baselineStorage = registry.storageSummary().totalModelBytes

        var manager: DownloadManager? = DownloadManager(
            store: store, layout: layout,
            transport: FoundationURLSessionTransport(),
            concurrentFileLimit: 1)
        let installer = ModelInstallService(
            downloadManager: manager!, registry: registry, layout: layout)

        let revision = descriptor.metadata["revision"] ?? "main"
        let job = try await stage("enqueue download") {
            try await installer.install(descriptor: descriptor, revision: revision)
        }
        print("[E2E]   job \(job.id) totalBytes=\(job.totalBytes)")

        // MARK: 5. Simulate an app relaunch mid-download: drop the manager
        // (process death — no cancel), build a fresh manager on the same
        // store, restore (in-flight files become .paused), re-register
        // sources, resume.
        try await stage("simulate process death") {
            // Wait until at least one byte has landed so the relaunch has
            // something real to resume.
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                let jobs = try await manager!.jobs()
                if let j = jobs.first(where: { $0.id == job.id }),
                   j.files.contains(where: { $0.bytesReceived > 0 }) {
                    print("[E2E]   bytes on disk at death: \(j.files[0].bytesReceived)")
                    break
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            // "Kill" the process: pause in-flight transfers (the transport
            // cancels its URLSession tasks) and drop the manager. The pause
            // path is what the OS would do on backgrounding; the manager's
            // event-pump task is `[weak self]` and terminates once the actor
            // is released.
            try await manager!.pause(jobID: job.id)
            manager = nil
            // Give the pump a beat to actually stop so no late event write
            // races the new manager's restore().
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let manager2 = DownloadManager(
            store: store, layout: layout,
            transport: FoundationURLSessionTransport(),
            concurrentFileLimit: 1)
        let installer2 = ModelInstallService(
            downloadManager: manager2, registry: registry, layout: layout)
        try await stage("restore + resume") {
            try await manager2.restore()
            // The fresh process re-registers sources from the descriptor
            // exactly as ModelInstallService.install would.
            let sources = try await installer2.sources(for: descriptor, revision: revision)
            await manager2.registerSources(sources, for: job.id)
            try await manager2.resume(jobID: job.id)
        }

        let completed = try await stage("download to completion") {
            try await waitForCompletion(manager: manager2, repoID: descriptor.repoID,
                                        timeout: 600)
        }
        XCTAssertTrue(completed, "download did not complete after relaunch")

        // On relaunch the original installer's watch task died with the old
        // manager. The app re-registers the model after confirming the job
        // completed — mirror that here.
        try await stage("register installed model") {
            let model = InstalledModel(repoID: descriptor.repoID, revision: revision,
                                       descriptor: descriptor, sizeOnDisk: job.totalBytes)
            try await registry.register(model)
        }

        // MARK: 6. Registry has the model; sha256 of the payload matches.
        let installed = try await stage("registry + sha verification") { () -> InstalledModel in
            let listed = registry.list()
            guard let m = listed.first(where: { $0.repoID == descriptor.repoID }) else {
                throw LocallyError.downloadFailed(
                    userMessage: "registered model missing",
                    technicalDetail: "registry has \(listed.map { $0.repoID })")
            }
            return m
        }
        let modelDir = layout.modelDirectory(repoID: descriptor.repoID, revision: installed.revision)
        let ggufPath = descriptor.requiredFiles.first { $0.path.hasSuffix(".gguf") }!.path
        let ggufURL = modelDir.appendingPathComponent(ggufPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ggufURL.path))
        if let expectedSHA = descriptor.requiredFiles.first(where: { $0.path == ggufPath })?.sha256 {
            let actualSHA = try DownloadManager.sha256Hex(of: ggufURL)
            XCTAssertEqual(actualSHA, expectedSHA.lowercased(), "sha256 must match HF LFS metadata")
            print("[E2E]   sha256 verified: \(actualSHA.prefix(16))…")
        }
        let afterInstall = registry.storageSummary().totalModelBytes
        XCTAssertGreaterThan(afterInstall, baselineStorage)
        print("[E2E]   storage: baseline=\(baselineStorage) afterInstall=\(afterInstall)")

        // MARK: 7. Runtime router picks GGUF; load the model.
        let caps = DeviceCapabilities(
            physicalMemory: profile.physicalMemory,
            metalAvailable: profile.metalAvailable,
            neuralEngineAvailable: profile.neuralEngineAvailable)
        let router = RuntimeRouter(runtimes: [GGUFRuntime()])
        let decision = router.decide(for: descriptor, on: caps)
        XCTAssertEqual(decision.runtimeKind, .gguf)

        var localDescriptor = descriptor
        localDescriptor.metadata["localPath"] = ggufURL.path
        let runtime = GGUFRuntime()
        try await stage("load model") {
            try await runtime.load(localDescriptor)
        }

        // MARK: 8. Chat inference at temperature 0, capture the benchmark.
        let request = AIRequest(
            model: localDescriptor,
            input: .text("Say hello in one short sentence."),
            parameters: GenerationParameters(temperature: 0, maxTokens: 24))
        var metadata: InferenceMetadata?
        var reply = ""
        try await stage("chat inference") {
            for try await event in runtime.run(request) {
                switch event {
                case .token(let t): reply += t
                case .partialText(let t): reply = t
                case .metadata(let m): metadata = m
                case .completed(let result):
                    metadata = result.metadata
                case .failed(let e): throw e
                default: break
                }
            }
        }
        print("[E2E]   reply: \(reply.prefix(120))")
        XCTAssertFalse(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "model must produce output")
        XCTAssertNotNil(metadata, "inference must emit metadata")
        if let metadata {
            print("[E2E]   tokens=\(metadata.generatedTokens ?? -1) "
                  + "tps=\(String(format: "%.1f", metadata.tokensPerSecond ?? 0)) "
                  + "ttft=\(String(format: "%.0f", (metadata.ttft ?? 0) * 1000))ms "
                  + "peak=\(metadata.peakMemoryBytes.map { "\($0 / (1 << 20))MB" } ?? "?")")
            try await registry.recordBenchmark(id: installed.id, sample: metadata)
        }

        // MARK: 9. Compatibility now shows measured speed.
        let refreshed = registry.get(id: installed.id)
        let benchmarks = refreshed?.benchmarks ?? []
        XCTAssertFalse(benchmarks.isEmpty, "recorded benchmark must persist")
        let measuredReport = engine.evaluate(descriptor: descriptor, device: profile,
                                             benchmarks: benchmarks)
        print("[E2E]   measured speed=\(measuredReport.speed)")
        if case .measured = measuredReport.speed { /* expected */ }
        else { XCTFail("after a recorded benchmark, speed must be .measured, got \(measuredReport.speed)") }

        // MARK: 10. Unload, delete, storage back to baseline.
        await stage("unload") { await runtime.unload() }
        try await stage("delete") {
            try await registry.delete(id: installed.id)
        }
        XCTAssertNil(registry.get(id: installed.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDir.path))
        let finalStorage = registry.storageSummary().totalModelBytes
        XCTAssertEqual(finalStorage, baselineStorage,
                       "after delete, storage must return to baseline")
        print("[E2E]   storage final=\(finalStorage) (baseline=\(baselineStorage))")
    }

    /// Poll the store until every file of the job for `repoID` is completed.
    private func waitForCompletion(manager: DownloadManager, repoID: String,
                                   timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var lastReported: Int64 = -1
        while Date() < deadline {
            let jobs = try await manager.jobs()
            if let job = jobs.first(where: { $0.modelRepoID == repoID }) {
                if job.files.allSatisfy({ $0.state == .completed }) { return true }
                if job.files.allSatisfy({ $0.state == .failed || $0.state == .cancelled }) {
                    let detail = job.files.compactMap(\.failureDetail).joined(separator: "; ")
                    print("[E2E]   job finished in failure: \(detail)")
                    return false
                }
                let received = job.files.reduce(Int64(0)) { $0 + $1.bytesReceived }
                if received != lastReported, job.totalBytes > 0 {
                    lastReported = received
                    let pct = String(format: "%.1f", 100.0 * Double(received) / Double(job.totalBytes))
                    print("[E2E]   downloading \(pct)% (\(received)/\(job.totalBytes))")
                }
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }
}
