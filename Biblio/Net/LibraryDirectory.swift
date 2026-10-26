import Foundation
import Observation

/// Reads public, unauthenticated library information.
nonisolated enum LibraryLookup {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpAdditionalHeaders = ["User-Agent": "Biblio/1.0 (Apple; SwiftUI patron app)"]
        return URLSession(configuration: c)
    }()

    /// Accepts "wccls", "WCCLS", "https://smpl.bibliocommons.com/", "smpl.bibliocommons.com/v2/search?…".
    static func subdomain(from input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        if !s.contains("://") && s.contains(".") { s = "https://" + s }
        if let host = URL(string: s)?.host(), host.hasSuffix("bibliocommons.com") {
            let label = host.split(separator: ".").first.map(String.init)
            return label == "www" || label == "bibliocommons" ? nil : label
        }
        let valid = s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        return valid ? s : nil
    }

    static func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await Throttle.shared.run { try await session.data(from: url) }
        guard let http = response as? HTTPURLResponse else { throw BiblioError.unexpected("No response") }
        return (data, http)
    }

    static func exists(_ subdomain: String) async -> Bool {
        let url = URL(string: "https://gateway.bibliocommons.com/v2/libraries/\(subdomain)/locations?limit=1")!
        return (try? await get(url).1.statusCode) == 200
    }

    /// Fetches name, brand colour, languages and catalog labels from the library's public search page.
    static func info(for subdomain: String) async throws -> LibraryInfo {
        let url = URL(string: "https://\(subdomain).bibliocommons.com/v2/search?query=library&searchType=keyword")!
        let (data, http) = try await get(url)
        guard http.statusCode == 200, http.url?.host()?.hasPrefix(subdomain + ".") == true else {
            throw BiblioError.unexpected("“\(subdomain)” is not a BiblioCommons library.")
        }
        let html = String(decoding: data, as: UTF8.self)
        guard let state = pageState(html) else {
            throw BiblioError.unexpected("“\(subdomain)” did not return a catalog page.")
        }
        let lib = state["entities"]["libraries"].object.values.first ?? .null
        let prefixes = ["FORMAT.", "AUDIENCE.", "FICTION_TYPE.", "LANGUAGE.", "sort.", "LANGUAGE_NAME."]
        let labels = state["localization"]["messages"].object.compactMapValues(\.string)
            .filter { k, _ in prefixes.contains { k.hasPrefix($0) } }
        return LibraryInfo(
            subdomain: subdomain,
            name: lib["fullName"].nonEmptyString ?? lib["longName"].nonEmptyString ?? subdomain.uppercased(),
            shortName: lib["shortName"].nonEmptyString,
            primaryColor: state["branding"]["primaryBrandColor"].string,
            website: lib["homeLink"].nonEmptyString,
            labels: labels,
            languages: state["localization"]["availableLanguages"].strings,
            users: [])
    }

    /// The JSON app state the site embeds in `<script type="application/json">`.
    static func pageState(_ html: String) -> JSON? {
        var search = html.startIndex..<html.endIndex
        while let open = html.range(of: #"<script[^>]*type="application/json"[^>]*>"#, options: .regularExpression, range: search),
              let close = html.range(of: "</script>", range: open.upperBound..<html.endIndex) {
            let body = html[open.upperBound..<close.lowerBound]
            if body.contains("\"branding\""), let json = try? JSON.parse(Data(body.utf8)) { return json }
            search = close.upperBound..<html.endIndex
        }
        return nil
    }
}

/// Autocompletion source: the partner list at bibliocommons.com/libraries-we-work-with,
/// fetched page by page in the background.
@Observable
final class LibraryDirectory {
    nonisolated struct Entry: Identifiable, Hashable, Sendable {
        var name: String
        var website: URL?
        var region: String?
        /// A wide (640×400) partner logo from the directory page.
        var logo: URL?
        var id: String { name }
        var iconKey: String { website?.host()?.lowercased() ?? name }
    }

    static let shared = LibraryDirectory()

    private(set) var entries: [Entry] = []
    private(set) var isLoading = false
    private var started = false

    func loadIfNeeded() {
        guard !started else { return }
        started = true
        isLoading = true
        Task {
            var next: URL? = URL(string: "https://www.bibliocommons.com/libraries-we-work-with")
            var seen = Set<String>()
            while let url = next {
                guard let (data, _) = try? await LibraryLookup.get(url) else { break }
                let html = String(decoding: data, as: UTF8.self)
                let page = Self.parse(html).filter { seen.insert($0.name).inserted }
                entries.append(contentsOf: page)
                next = Self.nextPage(html, base: url)
                if page.isEmpty { break }
            }
            isLoading = false
        }
    }

    func suggestions(for text: String) -> [Entry] {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { return [] }
        return entries.filter {
            $0.name.localizedCaseInsensitiveContains(t) || ($0.website?.host()?.localizedCaseInsensitiveContains(t) ?? false)
        }
        .prefix(12).map { $0 }
    }

    /// Guesses the catalog subdomain for a directory entry and confirms it against the gateway.
    nonisolated static func resolveSubdomain(for entry: Entry) async -> String? {
        var candidates: [String] = []
        if let host = entry.website?.host()?.lowercased() {
            let labels = host.split(separator: ".").map(String.init).filter { !["www", "com", "org", "gov", "net", "ca", "us", "edu", "info", "library", "lib"].contains($0) }
            candidates += labels
            if let first = labels.first { candidates.append(first + "library") }
        }
        let initials = entry.name.split(separator: " ").compactMap(\.first).map(String.init).joined().lowercased()
        candidates.append(initials)
        candidates.append(entry.name.lowercased().filter { $0.isLetter })
        for c in NSOrderedSet(array: candidates).compactMap({ $0 as? String }) where !c.isEmpty {
            if await LibraryLookup.exists(c) { return c }
        }
        return nil
    }

    private nonisolated static func parse(_ html: String) -> [Entry] {
        let pattern = #"<a[^>]*href="([^"]*)"[^>]*class="library-link[^"]*"[^>]*>.*?<img[^>]*alt="([^"]*)"[^>]*src="([^"]*)".*?(?:fs-cmsfilter-field="Region"[^>]*>([^<]*)<)?"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        return re.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            guard let name = g(2).map(HTMLForm.decode), !name.isEmpty else { return nil }
            return Entry(name: name, website: g(1).flatMap(URL.init(string:)), region: g(4), logo: g(3).flatMap(URL.init(string:)))
        }
    }

    private nonisolated static func nextPage(_ html: String, base: URL) -> URL? {
        guard let r = html.range(of: #"href="(\?[0-9a-f]+_page=\d+)"[^>]*class="[^"]*w-pagination-next"#, options: .regularExpression)
                ?? html.range(of: #"class="[^"]*w-pagination-next[^"]*"[^>]*href="(\?[0-9a-f]+_page=\d+)""#, options: .regularExpression)
        else { return nil }
        let chunk = String(html[r])
        guard let q = chunk.range(of: #"\?[0-9a-f]+_page=\d+"#, options: .regularExpression) else { return nil }
        return URL(string: String(chunk[q]), relativeTo: base)?.absoluteURL
    }
}
