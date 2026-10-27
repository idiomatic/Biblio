import Foundation
import Observation

/// Reads public, unauthenticated library information (through libbiblio, except icons).
nonisolated enum LibraryLookup {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpAdditionalHeaders = ["User-Agent": "Biblio/1.0 (Apple; SwiftUI patron app)"]
        return URLSession(configuration: c)
    }()

    /// Accepts "wccls", "WCCLS", "https://smpl.bibliocommons.com/", "smpl.bibliocommons.com/v2/search?…".
    static func subdomain(from input: String) -> String? {
        (try? Core.callNow(nil, ["op": "subdomainFrom", "input": input], as: String?.self)) ?? nil
    }

    /// Fetches a page from a library's own website (for icons), paced with the app's other requests.
    static func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await Throttle.shared.run { try await session.data(from: url) }
        guard let http = response as? HTTPURLResponse else { throw BiblioError.unexpected("No response") }
        return (data, http)
    }

    static func exists(_ subdomain: String) async -> Bool {
        (try? await Core.call(nil, ["op": "libraryExists", "subdomain": subdomain], as: Bool.self)) ?? false
    }

    /// Fetches name, brand colour, languages and catalog labels from the library's public search page.
    static func info(for subdomain: String) async throws -> LibraryInfo {
        do {
            return try await Core.call(nil, ["op": "libraryInfo", "subdomain": subdomain], as: LibraryInfo.self)
        } catch let failure as Core.Failure {
            throw BiblioError.unexpected(failure.message)
        }
    }
}

/// Autocompletion source: the partner list at bibliocommons.com/libraries-we-work-with,
/// fetched page by page in the background.
@Observable
final class LibraryDirectory {
    nonisolated struct Entry: Identifiable, Hashable, Sendable, Decodable {
        var name: String
        var website: URL?
        var region: String?
        /// A wide (640×400) partner logo from the directory page.
        var logo: URL?
        var id: String { name }
        var iconKey: String { website?.host()?.lowercased() ?? name }

        private enum CodingKeys: String, CodingKey { case name, website, region, logo }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            website = try c.decodeIfPresent(String.self, forKey: .website).flatMap(URL.init(string:))
            region = try c.decodeIfPresent(String.self, forKey: .region)
            logo = try c.decodeIfPresent(String.self, forKey: .logo).flatMap(URL.init(string:))
        }
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
            struct Page: Decodable, Sendable { var entries: [Entry]; var next: String? }
            var next: String? = nil
            var seen = Set<String>()
            repeat {
                var request: [String: Any] = ["op": "directoryPage"]
                if let next { request["url"] = next }
                guard let page = try? await Core.call(nil, request, as: Page.self) else { break }
                let fresh = page.entries.filter { seen.insert($0.name).inserted }
                entries.append(contentsOf: fresh)
                if fresh.isEmpty { break }
                next = page.next
            } while next != nil
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
        var request: [String: Any] = ["op": "resolveSubdomain", "name": entry.name]
        if let website = entry.website { request["website"] = website.absoluteString }
        return (try? await Core.call(nil, request, as: String?.self)) ?? nil
    }
}
