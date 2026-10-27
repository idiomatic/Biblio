import Foundation
import Observation

/// A client's most recent request to the library, for the window's status bar.
@Observable
final class FetchStatus {
    nonisolated struct Fetch: Sendable, Equatable {
        var title: String
        var url: URL
        var bytes: Int
    }

    private(set) var last: Fetch?
    /// Requests started but not finished.
    private(set) var active = 0
    /// Bumped whenever a request starts or finishes.
    private(set) var activity = 0

    func began() {
        active += 1
        activity += 1
    }

    func finished(_ fetch: Fetch?) {
        active = max(0, active - 1)
        activity += 1
        if let fetch { last = fetch }
    }

    /// The page's `<title>` for HTML, otherwise a name for the gateway endpoint.
    nonisolated static func title(url: URL, data: Data) -> String {
        if let html = String(data: data.prefix(64 * 1024), encoding: .utf8),
           let range = html.range(of: #"<title[^>]*>([^<]*)</title>"#, options: [.regularExpression, .caseInsensitive]) {
            let tag = String(html[range])
            let text = tag.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return HTMLForm.decode(text) }
        }
        // Gateway paths look like /v2/libraries/{subdomain}/{endpoint}/…
        let parts = url.pathComponents
        let rest = parts.firstIndex(of: "libraries").map { Array(parts.dropFirst($0 + 2)) } ?? Array(parts.dropFirst())
        switch rest.first {
        case "bibs": return rest.last == "availability" ? "Availability" : "Search"
        case "catalogbibs": return "Item Details"
        case "locations": return "Locations"
        case "holds": return "Holds"
        case "checkouts": return "Checked Out"
        case "borrowinghistory": return "Borrowing History"
        case "sessions": return "Sign In"
        case "accounts", "users": return "Account Settings"
        default: return rest.joined(separator: "/")
        }
    }
}
