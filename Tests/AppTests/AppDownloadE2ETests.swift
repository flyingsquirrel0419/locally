import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import XCTest
import LocallyCore
import LocallyHF
import LocallyStorage

/// Hosted end-to-end download tests against the REAL code path:
/// URLSessionBackgroundTransport + DownloadManager + FilesystemLayout in a
/// temporary root, hitting huggingface.co over the network (available in the
/// GitHub Actions simulator). These pin the on-device "model download does
/// not work" report: every layer is real except the filesystem root.
///
/// Hosted-test constraint: the test bundle is hosted in the Locally app,
/// whose launch already created the app's background session
/// ("me.teamwicked.locally.downloads"). Two live background sessions with
/// the SAME identifier in one process are undefined behavior (the second
/// receives no delegate callbacks — exactly the "started, 0 bytes" stall
/// seen in CI run 36946901860), so each test creates its transport with a
/// UNIQUE identifier and invalidates it in tearDown.
///
/// Chosen fixtures (small, stable, public, no auth):
/// - Qwen/Qwen2.5-0.5B-Instruct `config.json` (~700 B) and
///   `tokenizer.json` (~7 MB, not LFS — no oid; sha256 is fetched from the
///   HF API at test time with ?blobs=true).
/// - ggml-org/tiny-llamas `stories260K.gguf` (~1.1 MB LFS GGUF) for the
///   analyze → install → registry flow.
final class AppDownloadE2ETests: XCTestCase {
    private var tempRoot: URL!
    #if os(iOS)
    private var transport: URLSessionBackgroundTransport!
    /// DEBUG-only delegate-callback log from the background transport:
    /// progress/finish/error per task, so a stall shows exactly which
    /// callbacks (if any) the test's background session delivered.
    private let delegateLog = DelegateLog()
    #endif

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-dl-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        #if os(iOS)
        transport = URLSessionBackgroundTransport(
            sessionIdentifier: "me.teamwicked.locally.tests.\(UUID().uuidString)")
        transport.onDelegateEvent = { [delegateLog] line in
            delegateLog.append(line)
            print("[bg-session] \(line)")
        }
        #endif
    }

    override func tearDown() async throws {
        // Invalidate the per-test session so its identifier is released for
        // the next test (see the class doc comment).
        #if os(iOS)
        transport.invalidateAndCancel()
        transport = nil
        #endif
        try? FileManager.default.removeItem(at: tempRoot)
    }

    #if os(iOS)
    private func delegateDiagnostics() -> String {
        let lines = delegateLog.lines()
        return lines.isEmpty ? "<no delegate callbacks>" : lines.joined(separator: " | ")
    }

    /// Failure-message suffix with the background-session delegate callback
    /// log; empty off iOS.
    private func delegateSuffix() -> String {
        "; delegate: \(delegateDiagnostics())"
    }
    #else
    private func delegateSuffix() -> String { "" }
    #endif

    private func makeManager() -> DownloadManager {
        let layout = FilesystemLayout(root: tempRoot)
        let store = DownloadStore(directory: tempRoot.appendingPathComponent("store"))
        #if os(iOS)
        return DownloadManager(store: store, layout: layout, transport: transport)
        #else
        return DownloadManager(store: store, layout: layout,
                               transport: FoundationURLSessionTransport())
        #endif
    }

    private func waitForJob(_ manager: DownloadManager, id: UUID,
                            timeout: TimeInterval = 180) async -> DownloadJob? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let job = try? await manager.jobs().first(where: { $0.id == id }),
               job.isFinished {
                return job
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return try? await manager.jobs().first(where: { $0.id == id })
    }

    private func describe(_ job: DownloadJob?) -> String {
        guard let job else { return "<job missing>" }
        let files = job.files.map {
            "\($0.relativePath): \($0.state.rawValue) \($0.bytesReceived)/\($0.expectedSize)"
                + ($0.failureDetail.map { " [\($0)]" } ?? "")
        }.joined(separator: "; ")
        return "job \(job.id) files: \(files)"
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Fetch the sha256 for a repo file at test time: the HF API exposes it
    /// under siblings[].lfs.sha256 for LFS files when ?blobs=true is set.
    /// For non-LFS files HF serves the git blob sha1, not sha256 — so this
    /// returns nil and the test asserts size + a local sha match instead.
    private func fetchLFSHA256(repoID: String, revision: String, path: String) async throws -> String? {
        let client = HFClient()
        let info = try await client.repoInfo(RepoID(parsing: repoID), revision: revision)
        return info.siblings?.first(where: { $0.rfilename == path })?.lfs?.sha256
    }

    // MARK: - Real download through the real stack

    func testRealDownloadConfigAndTokenizer() async throws {
        let manager = makeManager()
        try await manager.restore()

        let base = "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct/resolve/main"
        // tokenizer.json in this repo is a plain git blob (~7 MB, no LFS
        // entry), so the API gives no sha256; the size check still applies.
        let tokenizerSHA = try await fetchLFSHA256(repoID: "Qwen/Qwen2.5-0.5B-Instruct",
                                                   revision: "main", path: "tokenizer.json")
        // Sizes come from the HF API (?blobs=true): verification needs a
        // real expected size, and hardcoding a number would rot.
        let client = HFClient()
        let info = try await client.repoInfo(RepoID(parsing: "Qwen/Qwen2.5-0.5B-Instruct"),
                                             revision: "main")
        func size(of path: String) throws -> Int64 {
            guard let size = info.siblings?.first(where: { $0.rfilename == path })?.size else {
                throw LocallyError.network(
                    userMessage: "Missing size for \(path)",
                    technicalDetail: "HF API returned no size for \(path)")
            }
            return size
        }
        let sizedSources = [
            DownloadSource(url: URL(string: "\(base)/config.json")!,
                           relativePath: "config.json",
                           expectedSize: try size(of: "config.json")),
            DownloadSource(url: URL(string: "\(base)/tokenizer.json")!,
                           relativePath: "tokenizer.json",
                           expectedSize: try size(of: "tokenizer.json"),
                           sha256: tokenizerSHA),
        ]
        let job = try await manager.enqueue(repoID: "Qwen/Qwen2.5-0.5B-Instruct",
                                            revision: "main", sources: sizedSources)
        let finished = await waitForJob(manager, id: job.id)
        XCTAssertNotNil(finished)
        XCTAssertTrue(finished?.files.allSatisfy { $0.state == .completed } ?? false,
                      "download must complete: \(describe(finished)); "
                      + "diagnostics: \(manager.recentDiagnostics().map(\.detail).joined(separator: " | "))"
                      + delegateSuffix())

        let installed = tempRoot.appendingPathComponent("Models/Qwen_Qwen2.5-0.5B-Instruct/main")
        let config = try Data(contentsOf: installed.appendingPathComponent("config.json"))
        XCTAssertEqual(Int64(config.count), sizedSources[0].expectedSize)
        let tokenizer = try Data(contentsOf: installed.appendingPathComponent("tokenizer.json"))
        XCTAssertEqual(Int64(tokenizer.count), sizedSources[1].expectedSize)
        if let tokenizerSHA {
            XCTAssertEqual(sha256Hex(tokenizer), tokenizerSHA,
                           "downloaded bytes must match the HF LFS sha256")
        }
    }

    // MARK: - Full flow: analyze → install → registry

    func testAnalyzeInstallRegistersTinyGGUF() async throws {
        let manager = makeManager()
        try await manager.restore()
        let registry = ModelRegistry(root: tempRoot)
        try await registry.load()
        let layout = FilesystemLayout(root: tempRoot)
        let installService = ModelInstallService(downloadManager: manager,
                                                 registry: registry, layout: layout)

        let reference = try HFRepoReference(parsing: "https://huggingface.co/ggml-org/tiny-llamas")
        let descriptor: ModelDescriptor
        do {
            descriptor = try await RepositoryAnalyzer().analyze(reference, client: HFClient())
        } catch {
            XCTFail("analyze failed: \(error)")
            return
        }
        // The analyzer must pick up the tiny GGUF; if the repo layout ever
        // changes, fail loudly rather than silently testing nothing.
        XCTAssertTrue(descriptor.requiredFiles.contains { $0.path.hasSuffix(".gguf") },
                      "expected a .gguf in requiredFiles, got \(descriptor.requiredFiles.map(\.path))")

        let revision = reference.revision ?? "main"
        let job = try await installService.install(descriptor: descriptor, revision: revision)

        // InstallService registers via a 1s-poll watch after completion;
        // wait for the registry entry, not just the job.
        let deadline = Date().addingTimeInterval(180)
        var installed: InstalledModel?
        while Date() < deadline {
            if let found = registry.list().first(where: { $0.repoID == "ggml-org/tiny-llamas" }) {
                installed = found
                break
            }
            if let current = try? await manager.jobs().first(where: { $0.id == job.id }),
               current.isFinished,
               !current.files.allSatisfy({ $0.state == .completed }) {
                break  // finished without success: stop waiting, assert below
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let finalJob = try? await manager.jobs().first(where: { $0.id == job.id })
        XCTAssertNotNil(installed,
                        "registry must contain the installed model: \(describe(finalJob)); "
                        + "diagnostics: \(manager.recentDiagnostics().map(\.detail).joined(separator: " | "))"
                        + delegateSuffix())
        XCTAssertEqual(installed?.descriptor.repoID, "ggml-org/tiny-llamas")
        XCTAssertGreaterThan(installed?.sizeOnDisk ?? 0, 0)
    }
    /// Lock-protected line buffer for the DEBUG delegate-callback log.
    private final class DelegateLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ line: String) {
            lock.lock()
            storage.append(line)
            lock.unlock()
        }

        func lines() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}
