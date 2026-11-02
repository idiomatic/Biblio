import Foundation
import Security

/// Stores patron PINs/passwords as generic-password Keychain items,
/// one service per library subdomain and one account per username,
/// and the remembered library cards as one more item.
nonisolated enum Keychain {
    private static func service(_ subdomain: String) -> String { "com.rbrian.Biblio.\(subdomain)" }
    private static let cardsService = "com.rbrian.Biblio.cards"

    private static func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func data(service: String, account: String) -> Data? {
        var q = query(service, account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func setData(_ data: Data, service: String, account: String, label: String) -> Bool {
        let q = query(service, account)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = label
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func password(subdomain: String, username: String) -> String? {
        data(service: service(subdomain), account: username).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    static func setPassword(_ password: String, subdomain: String, username: String) -> Bool {
        setData(Data(password.utf8), service: service(subdomain), account: username,
                label: "Biblio – \(subdomain).bibliocommons.com (\(username))")
    }

    static func delete(subdomain: String, username: String) {
        SecItemDelete(query(service(subdomain), username) as CFDictionary)
    }

    /// The remembered library cards, as `LibraryStore` encodes them.
    static var cards: Data? { data(service: cardsService, account: "cards") }

    @discardableResult
    static func setCards(_ cards: Data) -> Bool {
        setData(cards, service: cardsService, account: "cards", label: "Biblio – library cards")
    }
}
