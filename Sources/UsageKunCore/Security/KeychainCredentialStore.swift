import Foundation
import Security

public enum CredentialKey: String, CaseIterable {
    case openAIAdminKey = "openai_admin_key"
    case anthropicAdminKey = "anthropic_admin_key"
    case manualCookieHeader = "manual_cookie_header"
}

public final class KeychainCredentialStore {
    private let service: String

    public init(service: String = "dev.usagekun.app") {
        self.service = service
    }

    public func save(_ value: String, for key: CredentialKey) throws {
        let data = Data(value.utf8)
        let query = baseQuery(for: key)

        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }

    public func read(_ key: CredentialKey) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    public func hasValue(for key: CredentialKey) -> Bool {
        read(key)?.isEmpty == false
    }

    public func delete(_ key: CredentialKey) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
    }

    private func baseQuery(for key: CredentialKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
    }
}

public struct KeychainError: LocalizedError {
    public let status: OSStatus

    public var errorDescription: String? {
        "Keychain error: \(status)"
    }
}
