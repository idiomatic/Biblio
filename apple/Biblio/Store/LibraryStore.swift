import BiblioCore
import Foundation
import Observation
import SwiftUI

/// A library the user has added, with branding and labels read from its catalog page.
nonisolated struct LibraryInfo: Identifiable, Hashable, Codable, Sendable {
    var subdomain: String
    var name: String
    var shortName: String?
    var primaryColor: String?
    /// The library's own website, where its icon comes from.
    var website: String?
    /// Selected localized strings (FORMAT.*, AUDIENCE.*, LANGUAGE.*, sort.*) keyed as on the site.
    var labels: [String: String]
    var languages: [String]
    var users: [String]
    /// The library card barcode type chosen in the account view; Codabar until then.
    var cardSymbology: BarcodeSymbology?

    var id: String { subdomain }
    var baseURL: URL { URL(string: "https://\(subdomain).bibliocommons.com")! }
    var websiteURL: URL? { website.flatMap(URL.init(string:)) }
    /// Icons are keyed by website host, so a directory suggestion and the added library share one.
    var iconKey: String { websiteURL?.host()?.lowercased() ?? subdomain }

    func label(_ key: String) -> String? { labels[key] }

    func formatName(_ code: String) -> String {
        DisplayNames.shared.name("FORMAT \(code)", in: self) { biblio_format_name(code, $0, $1) } ?? code.prettified
    }

    func sortName(_ id: String) -> String {
        DisplayNames.shared.name("sort \(id)", in: self) { biblio_sort_name(id, $0, $1) } ?? id.prettified
    }

    /// The format codes with built-in names, for format pickers.
    static let formatCodes: [String] = {
        var count = 0
        guard let codes = biblio_format_codes(&count) else { return [] }
        return (0..<count).compactMap { codes[$0].map { String(cString: $0) } }
    }()

    /// The library's brand color, adjusted per appearance so tinted controls stay legible:
    /// lightened in dark mode and darkened in light mode until it reaches 4.5:1 contrast
    /// with the bar backgrounds.
    var tint: Color {
        guard let hex = primaryColor,
              let light = Core.take(biblio_readable_tint(hex, false)),
              let dark = Core.take(biblio_readable_tint(hex, true)) else { return .accentColor }
        return Color.dynamic(light: light, dark: dark) ?? .accentColor
    }
}

/// The core's display names for a library's codes. Rows ask on every render, so names are
/// cached per library until its labels change.
private nonisolated final class DisplayNames: @unchecked Sendable {
    static let shared = DisplayNames()
    private let lock = NSLock()
    private typealias Entry = (labels: [String: String], names: [String: String])
    private var cache: [String: Entry] = [:]

    func name(_ key: String, in library: LibraryInfo,
              _ call: (UnsafePointer<biblio_pair>?, Int) -> UnsafeMutablePointer<CChar>?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        var entry: Entry = cache[library.subdomain].flatMap { $0.labels == library.labels ? $0 : nil }
            ?? (library.labels, [:])
        if let name = entry.names[key] { return name }
        let labels = library.labels.sorted { $0.key < $1.key }
        let name = Core.withCStrings(labels.flatMap { [$0.key, $0.value] }) { c in
            let pairs = stride(from: 0, to: c.count, by: 2).map { biblio_pair(key: c[$0], value: c[$0 + 1]) }
            return pairs.withUnsafeBufferPointer { Core.take(call($0.baseAddress, $0.count)) }
        }
        entry.names[key] = name
        cache[library.subdomain] = entry
        return name
    }
}

/// A card's chosen color (a palette index) and monogram; either is the default until chosen.
nonisolated struct CardLook: Codable, Hashable, Sendable {
    var color: Int?
    var monogram: String?
    /// What the card is called in "Hold for …", instead of the library's first name.
    var name: String?
    var isDefault: Bool { color == nil && monogram == nil && name == nil }
}

/// A signed-in user's library card, remembered from the last sign-in so the cards can be
/// shown, and rotated between, without signing in to each.
nonisolated struct CardInfo: Identifiable, Hashable, Codable, Sendable {
    var subdomain: String
    var username: String
    var name: String
    var library: String
    var barcode: String
    /// The first name in the library's contact record, if it gave one.
    var firstName: String?

    var id: String { Self.id(subdomain: subdomain, username: username) }

    static func id(subdomain: String, username: String) -> String { "\(subdomain)/\(username)" }

    /// The card of `patron`, signed in as `username`, if the library gave a barcode.
    init?(library: LibraryInfo, username: String, patron: Patron) {
        guard let barcode = patron.barcode else { return nil }
        self.init(subdomain: library.subdomain, username: username, name: patron.name,
                  library: library.shortName ?? library.name, barcode: barcode, firstName: patron.firstName)
    }

    init(subdomain: String, username: String, name: String, library: String, barcode: String, firstName: String? = nil) {
        self.subdomain = subdomain
        self.username = username
        self.name = name
        self.library = library
        self.barcode = barcode
        self.firstName = firstName
    }
}

/// Persists added libraries and the usernames added for each. Passwords live in the Keychain.
@Observable
final class LibraryStore {
    static let shared = LibraryStore()

    private(set) var libraries: [LibraryInfo] = []
    private let key = "libraries.v1"
    private let lastLoginKey = "lastLogin.v1"
    private let scopesKey = "lastScopes.v1"
    private let looksKey = "cardLooks.v1"

    /// The colors and monograms the user chose for cards, by `CardInfo.id`.
    private(set) var looks: [String: CardLook] = [:]

    /// The cards each library's window last showed, so reopening it picks up where it was left.
    private(set) var scopes: [String: [String]] = [:]
    private let sectionsKey = "lastSections.v1"
    private let collapsedKey = "collapsedSidebarSections.v1"
    /// The sidebar item each library last had selected, as JSON.
    private var sections: [String: String] = [:]
    /// The sidebar sections collapsed in each library's windows ("Cards", "Catalog", "My Library").
    private var collapsed: [String: [String]] = [:]

    /// The remembered library cards, by `CardInfo.id`, kept in the Keychain.
    private(set) var cards: [String: CardInfo] = [:]
    /// The login opened most recently, in any window.
    private(set) var lastLogin: (subdomain: String, username: String)?

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([LibraryInfo].self, from: data) {
            libraries = list
        }
        if let data = Keychain.cards, let saved = try? JSONDecoder().decode([String: CardInfo].self, from: data) {
            cards = saved
        }
        // Version 1.5 chose one barcode type for every library.
        if let old = UserDefaults.standard.string(forKey: "cardSymbology") {
            if let symbology = BarcodeSymbology(rawValue: old) {
                for i in libraries.indices where libraries[i].cardSymbology == nil {
                    libraries[i].cardSymbology = symbology
                }
                save()
            }
            UserDefaults.standard.removeObject(forKey: "cardSymbology")
        }
        // Prerelease builds kept the cards in the defaults.
        UserDefaults.standard.removeObject(forKey: "cards.v1")
        scopes = UserDefaults.standard.dictionary(forKey: scopesKey) as? [String: [String]] ?? [:]
        sections = UserDefaults.standard.dictionary(forKey: sectionsKey) as? [String: String] ?? [:]
        collapsed = UserDefaults.standard.dictionary(forKey: collapsedKey) as? [String: [String]] ?? [:]
        if let data = UserDefaults.standard.data(forKey: looksKey),
           let saved = try? JSONDecoder().decode([String: CardLook].self, from: data) { looks = saved }
        if let pair = UserDefaults.standard.stringArray(forKey: lastLoginKey), pair.count == 2 {
            lastLogin = (pair[0], pair[1])
        }
    }

    func saveCard(_ card: CardInfo) {
        guard cards[card.id] != card else { return }
        cards[card.id] = card
        saveCards()
    }

    func noteLogin(subdomain: String, username: String) {
        guard !username.isEmpty else { return }
        lastLogin = (subdomain, username)
        UserDefaults.standard.set([subdomain, username], forKey: lastLoginKey)
    }

    /// Remembers the cards a window shows for a library (a guest's none is not remembered).
    func noteScope(subdomain: String, usernames: [String]) {
        guard !usernames.isEmpty, scopes[subdomain] != usernames else { return }
        scopes[subdomain] = usernames
        UserDefaults.standard.set(scopes, forKey: scopesKey)
    }

    /// What a card is called (its name in the sidebar and "Hold for …", and its chip's initial):
    /// the name chosen in its Appearance, else the library's first name for the account, else the
    /// first word of the account's name, else the username. `firstName` and `name` are the signed-in
    /// patron's, when there is one; otherwise those remembered with the card.
    func callName(subdomain: String, username: String, firstName: String? = nil, name: String? = nil) -> String {
        if let chosen = look(subdomain: subdomain, username: username).name, !chosen.isEmpty { return chosen }
        let card = cards[CardInfo.id(subdomain: subdomain, username: username)]
        if let first = firstName ?? card?.firstName, !first.isEmpty { return Self.tidied(first) }
        let full = name ?? card?.name ?? username
        return Self.tidied(full.split(separator: " ").first.map(String.init) ?? full)
    }

    /// A name a library keeps in capitals (or all lowercase) reads as a name; mixed case is left alone.
    static func tidied(_ name: String) -> String {
        name == name.uppercased() || name == name.lowercased() ? name.capitalized : name
    }

    func look(subdomain: String, username: String) -> CardLook {
        looks[CardInfo.id(subdomain: subdomain, username: username)] ?? CardLook()
    }

    func setLook(_ look: CardLook, subdomain: String, username: String) {
        let id = CardInfo.id(subdomain: subdomain, username: username)
        if look.isDefault { looks[id] = nil } else { looks[id] = look }
        if let data = try? JSONEncoder().encode(looks) { UserDefaults.standard.set(data, forKey: looksKey) }
    }

    func noteSection(_ section: AppSection, for subdomain: String) {
        guard let data = try? JSONEncoder().encode(section), let text = String(data: data, encoding: .utf8),
              sections[subdomain] != text else { return }
        sections[subdomain] = text
        UserDefaults.standard.set(sections, forKey: sectionsKey)
    }

    /// Whether a sidebar section is expanded in this library's windows; all start expanded.
    func sidebarSection(_ name: String, in subdomain: String) -> Binding<Bool> {
        Binding(get: { !(self.collapsed[subdomain] ?? []).contains(name) }, set: { expanded in
            var names = (self.collapsed[subdomain] ?? []).filter { $0 != name }
            if !expanded { names.append(name) }
            self.collapsed[subdomain] = names.isEmpty ? nil : names
            UserDefaults.standard.set(self.collapsed, forKey: self.collapsedKey)
        })
    }

    func section(for subdomain: String) -> AppSection? {
        sections[subdomain].flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(AppSection.self, from: $0) }
    }

    func library(_ subdomain: String) -> LibraryInfo? {
        libraries.first { $0.subdomain == subdomain }
    }

    var isSoleLogin: Bool { soleLogin != nil }

    /// The one library and user when that is all there is; the app then skips its menus.
    var soleLogin: (library: LibraryInfo, username: String)? {
        guard libraries.count == 1, let library = libraries.first, library.users.count == 1 else { return nil }
        return (library, library.users[0])
    }

    /// The barcode type shown for the library's cards.
    func symbology(for subdomain: String) -> BarcodeSymbology {
        library(subdomain)?.cardSymbology ?? .codabar
    }

    func setSymbology(_ symbology: BarcodeSymbology, for subdomain: String) {
        guard let i = libraries.firstIndex(where: { $0.subdomain == subdomain }) else { return }
        libraries[i].cardSymbology = symbology
        save()
    }

    func upsert(_ info: LibraryInfo) {
        if let i = libraries.firstIndex(where: { $0.subdomain == info.subdomain }) {
            var merged = info
            merged.users = libraries[i].users
            merged.cardSymbology = libraries[i].cardSymbology
            libraries[i] = merged
        } else {
            libraries.append(info)
        }
        save()
    }

    func remove(_ subdomain: String) {
        for user in library(subdomain)?.users ?? [] {
            Keychain.delete(subdomain: subdomain, username: user)
            BorrowedIndex.deleteFile(subdomain: subdomain, username: user)
        }
        libraries.removeAll { $0.subdomain == subdomain }
        cards = cards.filter { $0.value.subdomain != subdomain }
        save()
    }

    func addUser(_ username: String, password: String, to subdomain: String) {
        guard let i = libraries.firstIndex(where: { $0.subdomain == subdomain }) else { return }
        Keychain.setPassword(password, subdomain: subdomain, username: username)
        if !libraries[i].users.contains(username) { libraries[i].users.append(username) }
        save()
    }

    func removeUser(_ username: String, from subdomain: String) {
        guard let i = libraries.firstIndex(where: { $0.subdomain == subdomain }) else { return }
        Keychain.delete(subdomain: subdomain, username: username)
        BorrowedIndex.deleteFile(subdomain: subdomain, username: username)
        libraries[i].users.removeAll { $0 == username }
        cards[CardInfo.id(subdomain: subdomain, username: username)] = nil
        setLook(CardLook(), subdomain: subdomain, username: username)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(libraries) {
            UserDefaults.standard.set(data, forKey: key)
        }
        saveCards()
    }

    private func saveCards() {
        if let data = try? JSONEncoder().encode(cards) { Keychain.setCards(data) }
    }
}

extension String {
    /// "NEWLY_ACQUIRED" → "Newly acquired"
    nonisolated var prettified: String {
        let s = replacingOccurrences(of: "_", with: " ").lowercased()
        return s.prefix(1).uppercased() + s.dropFirst()
    }
}

extension Color {
    /// A color that resolves differently in light and dark appearance, from "#RRGGBB" strings.
    nonisolated static func dynamic(light: String, dark: String) -> Color? {
        func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
            guard hex.hasPrefix("#"), let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
            return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
        }
        guard let light = rgb(light), let dark = rgb(dark) else { return nil }
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        })
        #else
        return Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        })
        #endif
    }
}
