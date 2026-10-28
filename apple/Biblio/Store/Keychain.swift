import Foundation
import Security

/// Stores patron PINs/passwords as generic-password Keychain items,
/// one service per library subdomain and one account per username.
nonisolated enum Keychain {
    private static func service(_ subdomain: String) -> String { "com.rbrian.Biblio.\(subdomain)" }

    private static func query(_ subdomain: String, _ username: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service(subdomain),
         kSecAttrAccount as String: username]
    }

    static func password(subdomain: String, username: String) -> String? {
        var q = query(subdomain, username)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func setPassword(_ password: String, subdomain: String, username: String) -> Bool {
        let data = Data(password.utf8)
        let q = query(subdomain, username)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Biblio – \(subdomain).bibliocommons.com (\(username))"
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func delete(subdomain: String, username: String) {
        SecItemDelete(query(subdomain, username) as CFDictionary)
    }
}
