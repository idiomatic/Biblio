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

    var id: String { subdomain }
    var baseURL: URL { URL(string: "https://\(subdomain).bibliocommons.com")! }
    var websiteURL: URL? { website.flatMap(URL.init(string:)) }
    /// Icons are keyed by website host, so a directory suggestion and the added library share one.
    var iconKey: String { websiteURL?.host()?.lowercased() ?? subdomain }

    func label(_ key: String) -> String? { labels[key] }

    func formatName(_ code: String) -> String {
        if code == "UK" { return "4K Ultra HD Blu-ray" }
        return labels["FORMAT.\(code.lowercased())"] ?? Self.fallbackFormatNames[code] ?? code.prettified
    }

    func sortName(_ id: String) -> String {
        labels["sort.\(id.lowercased())"] ?? id.prettified
    }

    static let fallbackFormatNames: [String: String] = [
        "BK": "Book", "EBOOK": "eBook", "AB": "Downloadable Audiobook", "VIDEO_ONLINE": "Streaming Video",
        "GRAPHIC_NOVEL": "Graphic Novel", "GRAPHIC_NOVEL_DOWNLOAD": "Downloadable Graphic Novel",
        "PICTURE_BOOK": "Picture Book", "ONLINE_LEARNING": "Online Learning", "DVD": "DVD",
        "LPRINT": "Large Print", "MAG_ONLINE": "Online Magazine", "BOARD_BK": "Board Book",
        "BLURAY": "Blu-ray Disc", "MUSIC_CD": "Music CD", "BOOK_CD": "Audiobook CD", "BOARD_GAME": "Board Game",
        "BOOK_PAUDIO": "Book plus Audio", "EASY_READER": "Early Readers", "PLAYAWAY_AUDIOBOOK": "Preloaded Audiobook",
        "VIDEO_GAME": "Video Game", "THREE_D_OBJECT": "3D Object", "BOOK_CLUB_KIT": "Book Club Kit",
        "DVD_PBLURAY": "DVD plus Blu-ray", "KIT": "Kit", "BOOK_PCD": "Book plus CD", "ATLAS": "Atlas",
        "BR": "Braille", "MAG": "Magazine", "BOOK_PDVD": "Book plus DVD", "MN": "Printed Music",
        "NEWSPAPER": "Newspaper",
    ]

    /// The library's brand color, adjusted per appearance so tinted controls stay legible:
    /// lightened in dark mode and darkened in light mode until it reaches 4.5:1 contrast
    /// with the bar backgrounds.
    var tint: Color {
        guard let brand = primaryColor.flatMap(BrandRGB.init(hex:)) else { return .accentColor }
        return Color.dynamic(light: brand.readable(against: .lightBar, lighten: false),
                             dark: brand.readable(against: .darkBar, lighten: true))
    }
}

/// Persists added libraries and the usernames added for each. Passwords live in the Keychain.
@Observable
final class LibraryStore {
    static let shared = LibraryStore()

    private(set) var libraries: [LibraryInfo] = []
    private let key = "libraries.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([LibraryInfo].self, from: data) {
            libraries = list
        }
    }

    func library(_ subdomain: String) -> LibraryInfo? {
        libraries.first { $0.subdomain == subdomain }
    }

    func upsert(_ info: LibraryInfo) {
        if let i = libraries.firstIndex(where: { $0.subdomain == info.subdomain }) {
            var merged = info
            merged.users = libraries[i].users
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
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(libraries) {
            UserDefaults.standard.set(data, forKey: key)
        }
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
    nonisolated init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

/// sRGB color math for keeping brand colors readable (WCAG relative luminance and contrast).
nonisolated struct BrandRGB: Sendable {
    var r, g, b: Double

    static let white = BrandRGB(r: 1, g: 1, b: 1)
    static let black = BrandRGB(r: 0, g: 0, b: 0)
    /// Approximate toolbar/sidebar backgrounds in each appearance.
    static let lightBar = BrandRGB(r: 0.96, g: 0.96, b: 0.97)
    static let darkBar = BrandRGB(r: 0.17, g: 0.17, b: 0.18)

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }

    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    func contrast(with other: BrandRGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The smallest change in HSL lightness (keeping hue and saturation, so the brand stays
    /// recognizable) that reaches `minimum` contrast with `background`.
    func readable(against background: BrandRGB, lighten: Bool, minimum: Double = 4.5) -> BrandRGB {
        var (h, s, l) = hsl
        var c = self
        while c.contrast(with: background) < minimum, lighten ? l < 1 : l > 0 {
            l = lighten ? min(1, l + 0.02) : max(0, l - 0.02)
            c = BrandRGB(h: h, s: s, l: l)
        }
        return c
    }

    var hsl: (h: Double, s: Double, l: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        let h: Double = switch mx {
        case r: ((g - b) / d + (g < b ? 6 : 0)) / 6
        case g: ((b - r) / d + 2) / 6
        default: ((r - g) / d + 4) / 6
        }
        return (h, s, l)
    }

    init(h: Double, s: Double, l: Double) {
        guard s > 0 else { self.init(r: l, g: l, b: l); return }
        func hue(_ p: Double, _ q: Double, _ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        self.init(r: hue(p, q, h + 1 / 3), g: hue(p, q, h), b: hue(p, q, h - 1 / 3))
    }

    var color: Color { Color(red: r, green: g, blue: b) }
}

extension Color {
    /// A color that resolves differently in light and dark appearance.
    nonisolated static func dynamic(light: BrandRGB, dark: BrandRGB) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        })
        #else
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        })
        #endif
    }
}
