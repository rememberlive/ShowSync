// Copyright © 2026 Remember Chaitezvi. All rights reserved.
// Part of ShowSync — Remember Live.

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

    /// Precise read outcome — lets the gate distinguish a legitimately-absent
    /// license (gate to backup) from a transient read failure (fail OPEN).
    enum LoadResult {
        case found(String)
        case absent            // errSecItemNotFound — cleanly no license
        case error(OSStatus)   // any other failure — ambiguous (read glitch, auth, etc.)
    }

    /// Read the stored license with the precise outcome (absent vs error distinguished).
    static func loadResult() -> LoadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            if let data = item as? Data, let value = String(data: data, encoding: .utf8) {
                return .found(value)
            }
            return .error(status)   // success but unreadable payload → treat as ambiguous
        case errSecItemNotFound:
            return .absent
        default:
            return .error(status)
        }
    }

    /// Read the stored license string, or nil if none / on error.
    /// Thin wrapper over loadResult() so existing callers are unchanged.
    static func load() -> String? {
        if case .found(let value) = loadResult() { return value }
        return nil
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
