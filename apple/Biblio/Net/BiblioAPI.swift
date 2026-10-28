import BiblioCore
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

/// The library operations the app uses, each one libbiblio call.
extension BiblioClient {
    // MARK: Catalog

    func search(_ q: SearchQuery, page: Int, sort: String?, format: String?) async throws -> ListPage {
        try await fetch({ client, out, err in
            let filters = q.filters.sorted { $0.key < $1.key }
            return Core.withCStrings(filters.flatMap { [$0.key, $0.value] }) { c in
                let pairs = stride(from: 0, to: c.count, by: 2).map { biblio_pair(key: c[$0], value: c[$0 + 1]) }
                return Core.withCStrings([q.query, q.searchType, sort, format]) { s in
                    pairs.withUnsafeBufferPointer { buf in
                        var query = biblio_search_query(query: s[0], search_type: s[1], filters: buf.baseAddress,
                                                        filter_count: buf.count, page: Int64(page), sort: s[2], format: s[3])
                        return biblio_search(client, &query, out, err)
                    }
                }
            }
        }, free: biblio_list_page_free, ListPage.init)
    }

    func availability(_ metadataId: String) async throws -> [CopyAvailability] {
        try await fetch({ biblio_availability($0, metadataId, $1, $2) }, free: biblio_copy_list_free) {
            buffer($0.items, $0.items_count).map(CopyAvailability.init)
        }
    }

    /// Full record fields ("Details", "About", …). Opinion/UGC sections are never requested.
    func detailFields(_ metadataId: String) async throws -> [DetailField] {
        try await fetch({ biblio_details($0, metadataId, $1, $2) }, free: biblio_detail_list_free) {
            buffer($0.items, $0.items_count).map(DetailField.init)
        }
    }

    func locations() async throws -> [Location] {
        try await fetch({ biblio_locations($0, $1, $2) }, free: biblio_location_list_free) {
            buffer($0.items, $0.items_count).map(Location.init)
        }
    }

    // MARK: Borrowing

    func holds(page: Int, sort: String?) async throws -> ListPage {
        try await fetch({ biblio_holds($0, Int64(page), sort, $1, $2) }, free: biblio_list_page_free, ListPage.init)
    }

    func checkouts(page: Int, sort: String?) async throws -> ListPage {
        try await fetch({ biblio_checkouts($0, Int64(page), sort, $1, $2) }, free: biblio_list_page_free, ListPage.init)
    }

    func borrowingHistory(page: Int, sort: String?) async throws -> ListPage {
        try await fetch({ biblio_history($0, Int64(page), sort, $1, $2) }, free: biblio_list_page_free, ListPage.init)
    }

    // MARK: Holds

    func placeHold(_ bib: Bib, pickupBranch: String?) async throws {
        try await perform { biblio_place_hold($0, bib.id, bib.materialType, pickupBranch, $1) }
    }

    /// Cancels holds and returns the ones the library refused, with its reason
    /// (some libraries don't allow cancelling holds that are ready for pickup).
    @discardableResult
    func cancelHolds(_ holds: [Hold]) async throws -> [(hold: Hold, reason: String)] {
        let refused = try await fetch({ client, out, err in
            Core.withCStrings(holds.flatMap { [$0.id, $0.metadataId] }) { c in
                let refs = stride(from: 0, to: c.count, by: 2).map { biblio_hold_ref(id: c[$0], metadata_id: c[$0 + 1]) }
                return biblio_cancel_holds(client, refs, refs.count, out, err)
            }
        }, free: biblio_refusal_list_free) { list in
            buffer(list.items, list.items_count).map { (holdId: string($0.hold_id) ?? "", reason: string($0.reason) ?? "") }
        }
        return refused.compactMap { r in holds.first { $0.id == r.holdId }.map { ($0, r.reason) } }
    }

    // MARK: Settings

    /// Current values as shown on the account settings pages.
    func accountSettings() async throws -> (email: String?, pickup: String?, language: String?) {
        try await fetch({ biblio_account_settings($0, $1, $2) }, free: biblio_account_settings_free) {
            (string($0.email), string($0.pickup), string($0.language))
        }
    }

    /// Sets the first preferred pickup location (used for new holds).
    func setDefaultPickupLocation(_ branchId: String) async throws {
        try await perform { biblio_set_pickup($0, branchId, $1) }
    }

    func changeLanguage(_ code: String) async throws {
        try await perform { biblio_set_language($0, code, $1) }
    }

    /// Turns the library's record of this account's borrowing history on or off.
    func setBorrowingHistory(enabled: Bool) async throws {
        try await perform { biblio_set_borrowing_history($0, enabled, $1) }
    }

    func changeEmail(_ email: String) async throws {
        try await perform { biblio_change_email($0, email, $1) }
    }

    /// Changes the PIN/password, then keeps the Keychain in step so automatic re-login still works.
    func changePassword(current: String, new: String) async throws {
        try await perform { biblio_change_password($0, current, new, $1) }
        Keychain.setPassword(new, subdomain: subdomain, username: username)
    }
}
