import Foundation
import Security

enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "com.vikalppanseriya.MindfulHours"

    struct Failure: Error {
        let status: OSStatus
    }

    /// Nil when there is no item; throws when one may exist but can't be read (e.g. access was denied).
    static func read(account: String) throws -> Data? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query(account: account).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { $1 } as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default:
            NSLog("MindfulHours: keychain read failed: \(status)")
            throw Failure(status: status)
        }
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
