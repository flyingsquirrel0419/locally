import Foundation
import LocallyCore
import LocallyStorage

#if DEBUG
/// UI-test-only fixture seeder for the screenshot suite. Active ONLY when
/// the process is launched with `-UITestFixtures` (the LocallyUITests target
/// sets it); the flag is never set in any other context and this whole type
/// is compiled out of release builds.
///
/// Two phases, called from LocallyApp.init around the runtime starts:
/// 1. `prepareDiskStateIfNeeded()` — BEFORE DownloadRuntime.start(): writes
///    registry.json + model files and a mid-transfer DownloadJob to
///    Application Support, so restore() shows the Downloads tab an honest
///    in-flight job (no network is ever touched).
/// 2. `seedIfNeeded()` — AFTER ModelLibraryRuntime.start(): registers the
///    fixture models through the real ModelRegistry so per-model metadata
///    and size accounting go through production code.
@MainActor
enum UITestFixtures {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-UITestFixtures")
    }

    private static var seeded = false

    /// Directory the UI test asked the app to expose (SCREENSHOT_DIR env,
    /// injected via launchEnvironment). Recorded by
    /// configureScreenshotDirectory; the app writes nothing itself — the
    /// runner captures XCUIScreen screenshots — but future fixture helpers
    /// (e.g. copying a generated artifact out of the sandbox) use it.
    private(set) static var screenshotDirectory: URL?

    /// Remember the runner-provided output directory, if any.
    static func configureScreenshotDirectory() {
        guard isEnabled,
              let path = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"],
              !path.isEmpty else { return }
        screenshotDirectory = URL(fileURLWithPath: path)
    }

    private struct FixtureModel {
        let repo: String
        let name: String
        let revision: String
        let gguf: Bool
        let markUsed: Bool
    }

    private static let models: [FixtureModel] = [
        FixtureModel(repo: "fixtures/TinyStories-Demo", name: "TinyStories Demo (fixture)",
                     revision: "fixture-rev-1", gguf: true, markUsed: true),
        FixtureModel(repo: "fixtures/SmallChat-Demo", name: "SmallChat Demo (fixture)",
                     revision: "fixture-rev-2", gguf: false, markUsed: false),
    ]

    /// Write model payload files and the in-flight download job. Must run
    /// before DownloadRuntime.start() so the DownloadStore loads the job.
    static func prepareDiskStateIfNeeded() {
        guard isEnabled else { return }
        let layout = FilesystemLayout.applicationSupport()
        let fm = FileManager.default
        for model in models {
            let dir = layout.modelDirectory(repoID: model.repo, revision: model.revision)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let data = model.gguf ? minimalGGUF() : Data(repeating: 0xAB, count: 512 * 1024)
                try data.write(to: dir.appendingPathComponent(payloadName(for: model)))
            } catch {
                continue // fixture seeding is best-effort
            }
        }
        // One honest in-flight job: mid-download, ~38% through. The manager's
        // restore() flips .downloading → .paused, the Downloads tab renders
        // the real persisted state, and no transfer is ever started.
        var file = DownloadFileTask(relativePath: "model.gguf",
                                    expectedSize: 4_200_000_000, sha256: nil)
        file.state = .downloading
        file.bytesReceived = 1_600_000_000
        file.progress = 1_600_000_000.0 / 4_200_000_000.0
        let job = DownloadJob(modelRepoID: "fixtures/BigDemo-7B",
                              revision: "main", files: [file])
        do {
            let data = try JSONEncoder().encode([job])
            let storeDir = layout.downloadsRoot.appendingPathComponent("store", isDirectory: true)
            try fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
            try data.write(to: storeDir.appendingPathComponent("jobs.json"), options: .atomic)
        } catch {
            // Non-fatal: Downloads tab shows its empty state.
        }
    }

    /// Register the fixture models through the shared registry. Idempotent.
    func seedIfNeeded() {
        guard Self.isEnabled, !Self.seeded else { return }
        Self.seeded = true
        guard let registry = ModelLibraryRuntime.shared.holder.registry else { return }
        for model in Self.models {
            let payload = Self.minimalGGUF()
            let size = Int64(model.gguf ? payload.count : 512 * 1024)
            var descriptor = ModelDescriptor(
                repoID: model.repo,
                name: model.name,
                architecture: model.gguf ? "llama" : nil,
                modality: .text,
                parameterCount: model.gguf ? 131_072 : 1_100_000_000,
                quantization: model.gguf ? Quantization(bits: 32, scheme: "F32")
                                         : Quantization(bits: 4, scheme: "Q4_K_M"),
                formats: model.gguf ? [.gguf] : [.safetensors],
                requiredFiles: [RemoteModelFile(path: Self.payloadName(for: model), size: size)],
                supportedRuntimes: model.gguf ? [.gguf] : [.mlx],
                contextLength: 2048,
                metadata: ["revision": model.revision, "fixture": "true"]
            )
            descriptor.metadata["fixture"] = "true"
            let installed = InstalledModel(repoID: model.repo, revision: model.revision,
                                           descriptor: descriptor, sizeOnDisk: size,
                                           installedAt: Date().addingTimeInterval(-86400 * 7))
            do {
                try registry.register(installed)
                if model.markUsed { try? registry.markUsed(id: installed.id) }
            } catch {
                continue
            }
        }
    }

    private static func payloadName(for model: FixtureModel) -> String {
        model.gguf ? "model.gguf" : "model.safetensors"
    }

    // MARK: - Minimal valid GGUF (layout adapted from GGUFParserTests)

    /// A syntactically valid GGUF v3 header for a tiny llama model, with the
    /// declared tensor data zero-padded so the file is complete. The parser
    /// in GGUFRuntime.load accepts it; llama.cpp may refuse to run such a
    /// tiny graph, in which case the playground honestly shows the load
    /// error — either state is a real render, not a mock.
    static func minimalGGUF() -> Data {
        struct Builder {
            var data = Data()
            mutating func u32(_ v: UInt32) { var v = v.littleEndian; data.append(contentsOf: withUnsafeBytes(of: &v) { Array($0) }) }
            mutating func u64(_ v: UInt64) { var v = v.littleEndian; data.append(contentsOf: withUnsafeBytes(of: &v) { Array($0) }) }
            mutating func string(_ s: String) { let b = Array(s.utf8); u64(UInt64(b.count)); data.append(contentsOf: b) }
        }
        var b = Builder()
        b.u32(0x4655_4747) // "GGUF"
        b.u32(3)           // version
        b.u64(2)           // tensor count
        b.u64(7)           // kv count
        b.string("general.architecture"); b.u32(8); b.string("llama")
        b.string("general.name"); b.u32(8); b.string("TinyFixture")
        b.string("llama.context_length"); b.u32(4); b.u32(2048)
        b.string("llama.block_count"); b.u32(4); b.u32(1)
        b.string("llama.embedding_length"); b.u32(4); b.u32(64)
        b.string("llama.attention.head_count"); b.u32(4); b.u32(2)
        b.string("tokenizer.ggml.tokens"); b.u32(9); b.u32(8); b.u64(2)
        b.string("hello"); b.string("world")
        b.string("token_embd.weight"); b.u32(2); b.u64(64); b.u64(2); b.u32(0); b.u64(0)
        b.string("blk.0.attn_q.weight"); b.u32(2); b.u64(64); b.u64(64); b.u32(0); b.u64(4096)
        let tensorBytes = 64 * 2 * 4 + 64 * 64 * 4
        b.data.append(Data(repeating: 0, count: tensorBytes + 8192))
        return b.data
    }
}
#endif
