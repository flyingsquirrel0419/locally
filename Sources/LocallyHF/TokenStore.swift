import Foundation

/// Stores the Hugging Face access token. Implementations must never log,
/// persist to plaintext files, or expose the token beyond in-memory use.
public protocol TokenStore: Sendable {
    func readToken() throws -> String?
    func saveToken(_ token: String) throws
    func removeToken() throws
}

/// Volatile in-memory store for tests and non-Apple platforms.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private var token: String?
    private let lock = NSLock()

    public init(token: String? = nil) { self.token = token }

    public func readToken() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    public func saveToken(_ token: String) throws {
        lock.lock()
        defer { lock.unlock() }
        self.token = token
    }

    public func removeToken() throws {
        lock.lock()
        defer { lock.unlock() }
        token = nil
    }
}

#if canImport(Security)
import Security

/// Keychain-backed store. kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly:
/// usable while the app runs in the background after first unlock, and never
/// migrated to another device via backup.
public struct KeychainTokenStore: TokenStore {
    private let service = "me.teamwicked.locally.hf"
    private let account = "hf-token"

    public init() {}

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func readToken() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw TokenStoreError.keychain(status)
        }
    }

    public func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let status = SecItemCopyMatching(baseQuery as CFDictionary, nil)
        if status == errSecSuccess {
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw TokenStoreError.keychain(updateStatus)
            }
        } else if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw TokenStoreError.keychain(addStatus)
            }
        } else {
            throw TokenStoreError.keychain(status)
        }
    }

    public func removeToken() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.keychain(status)
        }
    }
}

public enum TokenStoreError: Error, Sendable {
    case keychain(OSStatus)
}
#endif
