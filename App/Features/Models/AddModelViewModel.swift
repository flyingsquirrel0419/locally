import Foundation
import LocallyCore
import LocallyHF
import LocallyStorage

/// Models tab: analyzes a pasted HF link/repo into a ModelDescriptor, then
/// hands the descriptor to the install service when the user downloads.
@MainActor
@Observable
final class AddModelViewModel {
    var input = ""
    var isAnalyzing = false
    var result: ModelDescriptor?
    var errorMessage: String?
    /// True once the install job was queued; the sheet switches to Downloads.
    var didQueueDownload = false

    private let analyzer = RepositoryAnalyzer()
    private var client: HFClient {
        #if canImport(Security)
        HFClient(tokenStore: KeychainTokenStore())
        #else
        HFClient(tokenStore: InMemoryTokenStore())
        #endif
    }

    /// The revision the descriptor was analyzed at (commit sha when the API
    /// returned one); pinned so installs fetch exactly what was analyzed.
    var pinnedRevision: String? {
        result?.metadata["revision"]
    }

    func analyze() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnalyzing else { return }
        isAnalyzing = true
        result = nil
        errorMessage = nil
        didQueueDownload = false
        Task {
            do {
                let reference = try HFRepoReference(parsing: trimmed)
                result = try await analyzer.analyze(reference, client: client)
            } catch let error as LocallyError {
                errorMessage = error.userMessage
            } catch {
                errorMessage = String(localized: "hf.error.unknown", table: "HF")
            }
            isAnalyzing = false
        }
    }

    /// Enqueue the analyzed descriptor through the install service.
    func download(using installService: ModelInstallService?) {
        guard let descriptor = result, let installService else {
            errorMessage = String(localized: "models.error.generic", table: "Models")
            return
        }
        let revision = pinnedRevision ?? "main"
        Task {
            do {
                _ = try await installService.install(descriptor: descriptor, revision: revision)
                didQueueDownload = true
            } catch let error as LocallyError {
                errorMessage = error.userMessage
            } catch {
                errorMessage = String(localized: "models.error.generic", table: "Models")
            }
        }
    }
}
