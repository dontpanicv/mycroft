import Foundation
import Security

/// Generic-password items in the app's keychain. Values are readable after the first unlock so background runs can
/// use them while the phone is locked, and never leave this device.
nonisolated enum Keychain {
    static let service = "dev.mycroft.secrets"

    static func read(_ account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(base(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = base(account)
            item.merge(attributes) { $1 }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }

    private static func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

nonisolated struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Keychain error \(status)" }
}

/// Names of the secrets Mycroft keeps.
nonisolated enum Secret {
    static let jev = "jev.apiKey"
    static let openAI = "openai.apiKey"
}
