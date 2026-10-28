import Foundation
import Observation

/// A client's most recent request to the library, for the window's status bar
/// (titled by libbiblio: the page's `<title>`, or a name for the gateway endpoint).
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
}
