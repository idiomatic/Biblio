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

/// A signed-in user's library card, remembered from the last sign-in so the cards can be
/// shown, and rotated between, without signing in to each.
nonisolated struct CardInfo: Identifiable, Hashable, Codable, Sendable {
    var subdomain: String
    var username: String
    var name: String
    var library: String
    var barcode: String

    var id: String { Self.id(subdomain: subdomain, username: username) }

    static func id(subdomain: String, username: String) -> String { "\(subdomain)/\(username)" }

    /// The card of `patron`, signed in as `username`, if the library gave a barcode.
    init?(library: LibraryInfo, username: String, patron: Patron) {
        guard let barcode = patron.barcode else { return nil }
        self.init(subdomain: library.subdomain, username: username, name: patron.name,
                  library: library.shortName ?? library.name, barcode: barcode)
    }

    init(subdomain: String, username: String, name: String, library: String, barcode: String) {
        self.subdomain = subdomain
        self.username = username
        self.name = name
        self.library = library
        self.barcode = barcode
    }
}

/// Persists added libraries and the usernames added for each. Passwords live in the Keychain.
@Observable
final class LibraryStore {
    static let shared = LibraryStore()

    private(set) var libraries: [LibraryInfo] = []
    private let key = "libraries.v1"
    private let lastLoginKey = "lastLogin.v1"

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

    func library(_ subdomain: String) -> LibraryInfo? {
        libraries.first { $0.subdomain == subdomain }
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
        libraries[i].users.removeAll { $0 == username }
        cards[CardInfo.id(subdomain: subdomain, username: username)] = nil
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
