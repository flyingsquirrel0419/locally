import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LocallyStorage
import LocallyCore

/// Live download against a small public file on huggingface.co.
/// Gated on LOCALLY_LIVE_DL=1 so CI never touches the network.
final class LiveDownloadIntegrationTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-dl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testLiveDownloadConfigFiles() async throws {
        guard ProcessInfo.processInfo.environment["LOCALLY_LIVE_DL"] == "1" else {
            throw XCTSkip("set LOCALLY_LIVE_DL=1 to run the live network test")
        }
        let layout = FilesystemLayout(root: tempRoot)
        let store = DownloadStore(directory: tempRoot.appendingPathComponent("store"))
        let manager = DownloadManager(store: store, layout: layout,
                                      transport: FoundationURLSessionTransport())

        let base = "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct/resolve/main"
        let configURL = URL(string: "\(base)/config.json")!
        let tokenizerURL = URL(string: "\(base)/tokenizer_config.json")!

        // Probe sizes via HEAD first so expectedSize is real.
        let configSize = try await Self.headSize(configURL)
        let tokenizerSize = try await Self.headSize(tokenizerURL)
        XCTAssertGreaterThan(configSize, 0)
        XCTAssertGreaterThan(tokenizerSize, 0)

        let job = try await manager.enqueue(
            repoID: "Qwen/Qwen2.5-0.5B-Instruct", revision: "main",
            sources: [DownloadSource(url: configURL, relativePath: "config.json",
                                     expectedSize: configSize),
                      DownloadSource(url: tokenizerURL, relativePath: "tokenizer_config.json",
                                     expectedSize: tokenizerSize)])

        let deadline = Date().addingTimeInterval(60)
        var completed = false
        while Date() < deadline {
            if let j = try await manager.jobs().first(where: { $0.id == job.id }),
               j.files.allSatisfy({ $0.state == .completed }) {
                completed = true
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(completed, "live download did not complete within 60 s")

        let installedConfig = tempRoot.appendingPathComponent(
            "Models/Qwen_Qwen2.5-0.5B-Instruct/main/config.json")
        let installedTokenizer = tempRoot.appendingPathComponent(
            "Models/Qwen_Qwen2.5-0.5B-Instruct/main/tokenizer_config.json")
        XCTAssertEqual(Int64(try Data(contentsOf: installedConfig).count), configSize)
        XCTAssertEqual(Int64(try Data(contentsOf: installedTokenizer).count), tokenizerSize)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: installedConfig))
        XCTAssertTrue(json is [String: Any], "config.json did not parse as JSON object")
    }

    private static func headSize(_ url: URL) async throws -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        // Disable gzip so content-length reflects the on-disk byte count.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocallyError.network(userMessage: "No HTTP response.",
                                       technicalDetail: "HEAD \(url) returned non-HTTP")
        }
        // Case-insensitive header lookup (corelibs-foundation header keys are
        // not reliably canonicalized).
        func header(_ name: String) -> String? {
            http.allHeaderFields.first(where: {
                ($0.key as? String)?.caseInsensitiveCompare(name) == .orderedSame
            })?.value as? String
        }
        if let length = header("x-linked-size"), let size = Int64(length) {
            return size  // HF resolve endpoints redirect to a CDN; x-linked-size is the true size
        }
        if let length = header("content-length"), let size = Int64(length) {
            return size
        }
        throw LocallyError.network(userMessage: "Could not determine file size.",
                                   technicalDetail: "HEAD \(url) status \(http.statusCode)")
    }
}
