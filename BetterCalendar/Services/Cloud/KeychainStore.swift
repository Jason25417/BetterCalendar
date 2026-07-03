//
//  KeychainStore.swift
//  BetterCalendar
//
//  API key 存系统 Keychain（不进 git、不进 UserDefaults）。
//

import Foundation
import Security

enum KeychainStore {
    private static let service = "com.jason.BetterCalendar"
    private static let account = "anthropic-api-key"

    static func saveAPIKey(_ key: String) {
        deleteAPIKey()   // 清旧条目（含早期未开同步的本地条目）
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // 随 iCloud 钥匙串跨端同步（端到端加密）：Mac 存一次，iPhone 直接可用
            kSecAttrSynchronizable as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(key.utf8),
        ]
        SecItemAdd(add as CFDictionary, nil)
    }

    static func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,   // 新(同步)旧(本地)条目都能读
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8),
              !s.isEmpty
        else { return nil }
        return s
    }

    static func deleteAPIKey() {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(base as CFDictionary)
    }
}
