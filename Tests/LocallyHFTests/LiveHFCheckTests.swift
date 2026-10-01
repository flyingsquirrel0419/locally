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

    /// GGUF-only repo: the analyzer must Range-fetch the chosen variant's
    /// header and surface params / layers / kvHeads / context / template
    /// from it — none of that is in a config.json (there isn't one).
    func testLiveGGUFHeaderAnalysis() async throws {
        guard liveEnabled else {
            throw XCTSkip("Set LOCALLY_LIVE_HF=1 to run the live Hugging Face check")
        }
        let client = HFClient(transport: URLSessionTransport(),
                              tokenStore: InMemoryTokenStore())
        let analyzer = RepositoryAnalyzer()
        let reference = try HFRepoReference(parsing: "bartowski/SmolLM2-135M-Instruct-GGUF")
        let descriptor = try await analyzer.analyze(reference, client: client)

        XCTAssertTrue(descriptor.formats.contains(.gguf))
        XCTAssertEqual(descriptor.metadata["gguf_architecture"], "llama")
        XCTAssertEqual(descriptor.metadata["chat_template"], "gguf")

        // Ground truth for SmolLM2-135M (Q4_K_M): 134.5M stored params,
        // 30 layers, 9 attn heads, 3 kv heads, 8192 context.
        let params = try XCTUnwrap(descriptor.parameterCount, "params must come from the GGUF header")
        XCTAssertEqual(params, 134_515_008, accuracy: 1_000_000)
        XCTAssertEqual(descriptor.contextLength, 8192)
        XCTAssertEqual(descriptor.architectureHints?.numLayers, 30)
        XCTAssertEqual(descriptor.architectureHints?.numAttentionHeads, 9)
        XCTAssertEqual(descriptor.architectureHints?.numKVHeads, 3)
        XCTAssertEqual(descriptor.architectureHints?.hiddenSize, 576)

        print("""

        === LIVE GGUF: \(descriptor.repoID) ===
          params:      \(params)
          layers:      \(descriptor.architectureHints?.numLayers.map(String.init) ?? "-")
          kvHeads:     \(descriptor.architectureHints?.numKVHeads.map(String.init) ?? "-")
          heads:       \(descriptor.architectureHints?.numAttentionHeads.map(String.init) ?? "-")
          hidden:      \(descriptor.architectureHints?.hiddenSize.map(String.init) ?? "-")
          context:     \(descriptor.contextLength.map(String.init) ?? "-")
          template:    \(descriptor.metadata["chat_template"] ?? "-")
          arch:        \(descriptor.metadata["gguf_architecture"] ?? "-")
          quant meta:  \(descriptor.metadata["quantization"] ?? "-")
        """)
    }
}
