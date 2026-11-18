import Foundation
import Security

enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "com.vikalppanseriya.MindfulHours"

    static func read(account: String) -> Data? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query(account: account).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { $1 } as CFDictionary, &item)
        if status != errSecSuccess && status != errSecItemNotFound {
            NSLog("MindfulHours: keychain read failed: \(status)")
        }
        return item as? Data
    }

    static func write(_ data: Data, account: String) {
        let update = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(query(account: account) as CFDictionary, update)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(account: account).merging([
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]) { $1 } as CFDictionary, nil)
        }
        if status != errSecSuccess {
            NSLog("MindfulHours: keychain write failed: \(status)")
        }
    }

    static func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }

    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
