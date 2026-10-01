import Foundation
import LocallyCore
import LocallyHF

/// Settings: Hugging Face token entry and verification.
@MainActor
@Observable
final class HFSettingsViewModel {
    var tokenInput = ""
    var connectedUser: String?
    var hasStoredToken = false
    var isVerifying = false
    var errorMessage: String?

    private let tokenStore: any TokenStore
    private let client: HFClient

    init() {
        #if canImport(Security)
        tokenStore = KeychainTokenStore()
        #else
        tokenStore = InMemoryTokenStore()
        #endif
        client = HFClient(tokenStore: tokenStore)
    }

    func load() {
        do {
            hasStoredToken = try tokenStore.readToken() != nil
        } catch {
            errorMessage = String(localized: "hf.error.keychain", table: "HF")
        }
    }

    func saveToken() {
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        do {
            try tokenStore.saveToken(token)
            tokenInput = ""
            hasStoredToken = true
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "hf.error.keychain", table: "HF")
        }
    }

    func verify() {
        guard !isVerifying else { return }
        isVerifying = true
        errorMessage = nil
        Task {
            do {
                connectedUser = try await client.verifyToken()
            } catch let error as LocallyError {
                errorMessage = error.userMessage
                connectedUser = nil
            } catch {
                errorMessage = String(localized: "hf.error.unknown", table: "HF")
                connectedUser = nil
            }
            isVerifying = false
        }
    }

    func removeToken() {
        do {
            try tokenStore.removeToken()
        } catch {
            // Removal failure still clears local state; a failing Keychain
            // entry is treated as unreadable.
        }
        hasStoredToken = false
        connectedUser = nil
    }
}
