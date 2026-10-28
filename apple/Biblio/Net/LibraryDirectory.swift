import BiblioCore
import Foundation
import Observation

/// Reads public, unauthenticated library information through libbiblio.
nonisolated enum LibraryLookup {
    /// Accepts "wccls", "WCCLS", "https://smpl.bibliocommons.com/", "smpl.bibliocommons.com/v2/search?…".
    static func subdomain(from input: String) -> String? {
        Core.take(biblio_subdomain_from(input))
    }

    static func exists(_ subdomain: String) async -> Bool {
        (try? await Core.run { biblio_library_exists(subdomain) }) ?? false
    }

    /// Fetches name, brand colour, languages and catalog labels from the library's public search page.
    static func info(for subdomain: String) async throws -> LibraryInfo {
        let info = try await Core.run {
            try Core.fetch({ biblio_library_info(subdomain, $0, $1) }, free: biblio_library_info_free, LibraryInfo.init)
        }
        guard let info else { throw BiblioError.unexpected("The library returned an unexpected response.") }
        return info
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
            var next: String? = nil
            var seen = Set<String>()
            repeat {
                let url = next
                guard let page = try? await Core.run({
                    try Core.fetch({ biblio_directory_page(url, $0, $1) }, free: biblio_directory_page_free) {
                        (entries: buffer($0.entries, $0.entries_count).map(Entry.init), next: string($0.next))
                    }
                }) ?? nil else { break }
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
        let website = entry.website?.absoluteString
        return (try? await Core.run { Core.take(biblio_resolve_subdomain(entry.name, website)) }) ?? nil
    }
}
