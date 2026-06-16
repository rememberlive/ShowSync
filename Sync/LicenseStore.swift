import Foundation
import Security

/// Minimal macOS Keychain storage for the ShowSync license blob.
/// Stores one generic-password item (service+account fixed). More tamper-resistant
/// than a plaintext file in Application Support, and survives app-data deletion.
enum LicenseStore {
    private static let service = "africa.remember.Sync.license"
    private static let account = "license"

    /// Save (or overwrite) the license string. Returns true on success.
    @discardableResult
    static func save(_ value: String) -> Bool {
        let data = Data(value.utf8)
        // Delete any existing item first, then add fresh (simplest correct upsert).
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Read the stored license string, or nil if none / on error.
    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Remove the stored license item. Returns true if removed or already absent.
    @discardableResult
    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
