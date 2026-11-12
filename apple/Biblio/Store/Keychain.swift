import Foundation
import Security

/// Stores patron PINs/passwords as generic-password Keychain items,
/// one service per library subdomain and one account per username,
/// and the remembered library cards as one more item.
///
/// Items live in the data-protection keychain, readable only while the device is unlocked and
/// never restored to another device. On macOS, items saved by earlier versions in the file-based
/// login keychain move across when first read; if this build can't use the data-protection
/// keychain (no entitlement), it keeps using the login keychain.
nonisolated enum Keychain {
    private static func service(_ subdomain: String) -> String { "com.rbrian.Biblio.\(subdomain)" }
    private static let cardsService = "com.rbrian.Biblio.cards"
    private static var accessible: CFString { kSecAttrAccessibleWhenUnlockedThisDeviceOnly }

    /// `legacy` addresses macOS's file-based login keychain instead of the data-protection one.
    private static func query(_ service: String, _ account: String, legacy: Bool = false) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        #if os(macOS)
        if !legacy { q[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return q
    }

    private static func read(_ q: [String: Any]) -> (data: Data, label: String?)? {
        var q = q
        q[kSecReturnData as String] = true
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let item = out as? [String: Any], let data = item[kSecValueData as String] as? Data else { return nil }
        return (data, item[kSecAttrLabel as String] as? String)
    }

    private static func data(service: String, account: String) -> Data? {
        if let found = read(query(service, account)) { return found.data }
        #if os(macOS)
        // Saved by an earlier version: move it to the data-protection keychain.
        let old = query(service, account, legacy: true)
        guard let found = read(old) else { return nil }
        if write(found.data, service: service, account: account, label: found.label ?? "Biblio", legacy: false) == errSecSuccess {
            SecItemDelete(old as CFDictionary)
        }
        return found.data
        #else
        return nil
        #endif
    }

    private static func write(_ data: Data, service: String, account: String, label: String, legacy: Bool) -> OSStatus {
        let q = query(service, account, legacy: legacy)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data,
                                                       kSecAttrAccessible as String: accessible] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = accessible
        add[kSecAttrLabel as String] = label
        return SecItemAdd(add as CFDictionary, nil)
    }

    private static func setData(_ data: Data, service: String, account: String, label: String) -> Bool {
        var status = write(data, service: service, account: account, label: label, legacy: false)
        #if os(macOS)
        if status == errSecSuccess {
            SecItemDelete(query(service, account, legacy: true) as CFDictionary)
        } else if status == errSecMissingEntitlement {
            status = write(data, service: service, account: account, label: label, legacy: true)
        }
        #endif
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
        #if os(macOS)
        SecItemDelete(query(service(subdomain), username, legacy: true) as CFDictionary)
        #endif
    }

    /// The remembered library cards, as `LibraryStore` encodes them.
    static var cards: Data? { data(service: cardsService, account: "cards") }

    @discardableResult
    static func setCards(_ cards: Data) -> Bool {
        setData(cards, service: cardsService, account: "cards", label: "Biblio – library cards")
    }
}
