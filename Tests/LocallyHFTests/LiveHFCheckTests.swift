import Foundation
import XCTest
@testable import LocallyHF
import LocallyCore

/// Optional live check against the real Hugging Face API. Runs only when
/// LOCALLY_LIVE_HF=1 is set in the environment; skipped otherwise.
final class LiveHFCheckTests: XCTestCase {
    private var liveEnabled: Bool {
        ProcessInfo.processInfo.environment["LOCALLY_LIVE_HF"] == "1"
    }

    func testLiveAnalyzePublicRepos() async throws {
        guard liveEnabled else {
            throw XCTSkip("Set LOCALLY_LIVE_HF=1 to run the live Hugging Face check")
        }
        let client = HFClient(transport: URLSessionTransport(),
                              tokenStore: InMemoryTokenStore())
        let analyzer = RepositoryAnalyzer()

        for raw in ["mlx-community/Qwen2.5-0.5B-Instruct-4bit",
                    "Qwen/Qwen2.5-0.5B-Instruct-GGUF"] {
            let reference = try HFRepoReference(parsing: raw)
            let descriptor = try await analyzer.analyze(reference, client: client)
            print("""

            === LIVE: \(descriptor.repoID) ===
              modality:    \(descriptor.modality.rawValue)
              arch:        \(descriptor.architecture ?? "-")
              formats:     \(descriptor.formats.map(\.rawValue).joined(separator: ", "))
              params:      \(descriptor.parameterCount.map { "\($0)" } ?? "-")
              quant:       \(descriptor.quantization.map { "\($0.bits)bit \($0.scheme ?? "")" } ?? "-")
              context:     \(descriptor.contextLength.map { "\($0)" } ?? "-")
              download:    \(descriptor.totalDownloadSize.map { "\($0) bytes" } ?? "-")
              weight mem:  \(descriptor.estimatedWeightMemory.map { "\($0) bytes" } ?? "-")
              runtimes:    \(descriptor.supportedRuntimes.map(\.rawValue).joined(separator: ", "))
              files:       \(descriptor.requiredFiles.count)
              remoteCode:  \(descriptor.metadata["requiresRemoteCode"] ?? "false")
            """)
        }
    }
}
