import Foundation
import Security

/// Generic-password items in the app's keychain. Values are readable after the first unlock so background runs can
/// use them while the phone is locked, and never leave this device.
nonisolated enum Keychain {
    static let service = "dev.mycroft.secrets"

    static func read(_ account: String) -> String? {
        if case .found(let value) = lookup(account) { return value }
        return nil
    }

    enum Lookup {
        case found(String)
        case notFound
        /// The keychain could not answer (e.g. before the first unlock after a restart): not the same as missing.
        case failed(OSStatus)
    }

    static func lookup(_ account: String) -> Lookup {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { return .failed(status) }
            return .found(value)
        case errSecItemNotFound:
            return .notFound
        default:
            return .failed(status)
        }
    }

    /// Adds an item only if none exists; returns false when one already does.
    static func addIfMissing(_ value: String, for account: String) throws -> Bool {
        var item = base(account)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return true
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
