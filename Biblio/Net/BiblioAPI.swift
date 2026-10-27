import Foundation

/// Parameters for a catalog search (`POST /bibs/search`).
nonisolated struct SearchQuery: Hashable, Sendable {
    var query: String
    /// "smart" for keyword searches, "bl" for field-qualified (advanced) queries.
    var searchType: String = "smart"
    /// Extra filters, e.g. `["f_on_order": "true", "f_AUDIENCE": "adult"]`.
    var filters: [String: String] = [:]

    var isEmpty: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty }

    static func newTitles(onOrder: Bool) -> SearchQuery {
        SearchQuery(query: "nw:[0 TO 180]", searchType: "bl", filters: ["f_on_order": onOrder ? "true" : "false"])
    }
}

/// The library operations the app uses, each one libbiblio request.
extension BiblioClient {
    // MARK: Catalog

    func search(_ q: SearchQuery, page: Int, sort: String?, format: String?) async throws -> ListPage {
        var request: [String: Any] = ["op": "search", "query": q.query, "searchType": q.searchType,
                                      "filters": q.filters, "page": page]
        if let sort { request["sort"] = sort }
        if let format { request["format"] = format }
        return try await call(request, as: CoreListPage.self).listPage
    }

    func availability(_ metadataId: String) async throws -> [CopyAvailability] {
        try await call(["op": "availability", "metadataId": metadataId])
    }

    /// Full record fields ("Details", "About", …). Opinion/UGC sections are never requested.
    func detailFields(_ metadataId: String) async throws -> [DetailField] {
        try await call(["op": "details", "metadataId": metadataId])
    }

    func locations() async throws -> [Location] {
        try await call(["op": "locations"])
    }

    // MARK: Borrowing

    func holds(page: Int, sort: String?) async throws -> ListPage {
        try await borrowing("holds", page: page, sort: sort)
    }

    func checkouts(page: Int, sort: String?) async throws -> ListPage {
        try await borrowing("checkouts", page: page, sort: sort)
    }

    func borrowingHistory(page: Int, sort: String?) async throws -> ListPage {
        try await borrowing("history", page: page, sort: sort)
    }

    private func borrowing(_ op: String, page: Int, sort: String?) async throws -> ListPage {
        var request: [String: Any] = ["op": op, "page": page]
        if let sort { request["sort"] = sort }
        return try await call(request, as: CoreListPage.self).listPage
    }

    // MARK: Holds

    func placeHold(_ bib: Bib, pickupBranch: String?) async throws {
        var request: [String: Any] = ["op": "placeHold", "metadataId": bib.id, "materialType": bib.materialType]
        if let pickupBranch { request["pickupBranch"] = pickupBranch }
        _ = try await call(request, as: Bool.self)
    }

    /// Cancels holds and returns the ones the library refused, with its reason
    /// (some libraries don't allow cancelling holds that are ready for pickup).
    @discardableResult
    func cancelHolds(_ holds: [Hold]) async throws -> [(hold: Hold, reason: String)] {
        struct Result: Decodable, Sendable {
            struct Refusal: Decodable, Sendable { var holdId: String; var reason: String }
            var refused: [Refusal]
        }
        let result = try await call(["op": "cancelHolds",
                                     "holds": holds.map { ["id": $0.id, "metadataId": $0.metadataId] }],
                                    as: Result.self)
        return result.refused.compactMap { r in holds.first { $0.id == r.holdId }.map { ($0, r.reason) } }
    }

    // MARK: Settings

    /// Current values as shown on the account settings pages.
    func accountSettings() async throws -> (email: String?, pickup: String?, language: String?) {
        struct Settings: Decodable, Sendable { var email: String?; var pickup: String?; var language: String? }
        let s = try await call(["op": "accountSettings"], as: Settings.self)
        return (s.email, s.pickup, s.language)
    }

    /// Sets the first preferred pickup location (used for new holds).
    func setDefaultPickupLocation(_ branchId: String) async throws {
        _ = try await call(["op": "setPickup", "branchId": branchId], as: Bool.self)
    }

    func changeLanguage(_ code: String) async throws {
        _ = try await call(["op": "setLanguage", "code": code], as: Bool.self)
    }

    /// Turns the library's record of this account's borrowing history on or off.
    func setBorrowingHistory(enabled: Bool) async throws {
        _ = try await call(["op": "setBorrowingHistory", "enabled": enabled], as: Bool.self)
    }

    func changeEmail(_ email: String) async throws {
        _ = try await call(["op": "changeEmail", "email": email], as: Bool.self)
    }

    /// Changes the PIN/password, then keeps the Keychain in step so automatic re-login still works.
    func changePassword(current: String, new: String) async throws {
        _ = try await call(["op": "changePassword", "current": current, "new": new], as: Bool.self)
        Keychain.setPassword(new, subdomain: subdomain, username: username)
    }
}

/// A list page as the core returns it, before its rows become `ListEntry` values.
nonisolated struct CoreListPage: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        struct Status: Decodable, Sendable { var kind: String; var ready: Bool?; var position: Int?; var due: String? }
        var id: String
        var bib: Bib
        var kind: String
        var serverIndex: Int
        var hold: Hold?
        var checkout: Checkout?
        var history: HistoryEntry?
        var accountStatus: Status?
    }
    struct FacetValue: Decodable, Sendable { var value: String; var count: Int }
    struct CoreFacet: Decodable, Sendable { var id: String; var values: [FacetValue] }

    var entries: [Entry]
    var page: Int
    var pages: Int
    var count: Int
    var pageSize: Int
    var facets: [CoreFacet]?
    var sortOptions: [String]?
    var appliedSort: String?

    var listPage: ListPage {
        ListPage(entries: entries.compactMap(\.listEntry), page: page, pages: pages, count: count, pageSize: pageSize,
                 facets: (facets ?? []).map { Facet(id: $0.id, values: $0.values.map { ($0.value, $0.count) }) },
                 sortOptions: sortOptions ?? [], appliedSort: appliedSort)
    }
}

nonisolated private extension CoreListPage.Entry {
    var listEntry: ListEntry? {
        let kind: ListEntry.Kind
        switch self.kind {
        case "hold": guard let hold else { return nil }; kind = .hold(hold)
        case "checkout": guard let checkout else { return nil }; kind = .checkout(checkout)
        case "history": guard let history else { return nil }; kind = .history(history)
        default: kind = .catalog
        }
        let status: AccountStatus? = accountStatus.map { s in
            s.kind == "checkedOut" ? .checkedOut(due: s.due) : .onHold(ready: s.ready ?? false, position: s.position)
        }
        let isCatalog = kind == .catalog
        return ListEntry(id: id, bib: bib, kind: kind, serverIndex: serverIndex,
                         catalogStatus: isCatalog ? status : nil, catalogHold: isCatalog ? hold : nil)
    }
}
