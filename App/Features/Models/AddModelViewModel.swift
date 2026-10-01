import Foundation
import LocallyCore
import LocallyHF

/// Models tab: analyzes a pasted HF link/repo into a ModelDescriptor.
@MainActor
@Observable
final class AddModelViewModel {
    var input = ""
    var isAnalyzing = false
    var result: ModelDescriptor?
    var errorMessage: String?

    private let analyzer = RepositoryAnalyzer()
    private var client: HFClient {
        #if canImport(Security)
        HFClient(tokenStore: KeychainTokenStore())
        #else
        HFClient(tokenStore: InMemoryTokenStore())
        #endif
    }

    func analyze() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnalyzing else { return }
        isAnalyzing = true
        result = nil
        errorMessage = nil
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
}
