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

extension BiblioClient {
    // MARK: Catalog

    func search(_ q: SearchQuery, page: Int, sort: String?, format: String?) async throws -> ListPage {
        var body: [String: JSON] = [
            "query": .string(q.query),
            "searchType": .string(q.searchType),
            "page": .number(Double(page)),
            "locale": .string(locale),
        ]
        for (k, v) in q.filters { body[k] = .string(v) }
        if let sort { body["sort"] = .string(sort) }
        if let format { body["f_FORMAT"] = .string(format) }
        // Signed in, the response also lists this account's holds and checkouts among the results.
        let json = try await send("POST", "bibs/search", body: .object(body), authenticated: !isGuest)
        let search = json["catalogSearch"]
        let bibs = json["entities"]["bibs"]
        let (statuses, holds) = Self.accountStatuses(json["entities"])
        let entries = search["results"].array.enumerated().compactMap { i, r -> ListEntry? in
            guard let id = r["representative"].string, let bib = Bib(json: bibs[id]) else { return nil }
            // A title can group several editions; any of them held or checked out counts.
            let ids = [id] + r["manifestations"].strings
            return ListEntry(id: id, bib: bib, kind: .catalog, serverIndex: (page - 1) * 25 + i,
                             catalogStatus: ids.lazy.compactMap { statuses[$0] }.first,
                             catalogHold: ids.lazy.compactMap { holds[$0] }.first)
        }
        let facets = search["fields"].array.map { f in
            Facet(id: f["id"].string ?? "",
                  values: f["fieldFilters"].array.compactMap { v in
                      v["value"].string.map { ($0, v["count"].int ?? 0) }
                  })
        }
        let sorts = search["sortBys"].array.compactMap { $0["id"].string }
        return ListPage(entries: entries,
                        page: search[path: "pagination.page"].int ?? page,
                        pages: search[path: "pagination.pages"].int ?? page,
                        count: search[path: "pagination.count"].int ?? entries.count,
                        pageSize: search[path: "pagination.limit"].int ?? 25,
                        facets: facets,
                        sortOptions: sorts,
                        appliedSort: search["sortBys"].array.first { $0["applied"].bool == true }?["id"].string)
    }

    /// Account status by metadata id, from the `entities.holds` / `entities.checkouts` that
    /// authenticated catalog responses include. Checkouts win over holds.
    private static func accountStatuses(_ entities: JSON) -> (statuses: [String: AccountStatus], holds: [String: Hold]) {
        var out: [String: AccountStatus] = [:]
        var holds: [String: Hold] = [:]
        for h in entities["holds"].object.values {
            guard let hold = Hold(json: h) else { continue }
            out[hold.metadataId] = .onHold(ready: hold.status == "READY_FOR_PICKUP", position: hold.position)
            holds[hold.metadataId] = hold
        }
        for c in entities["checkouts"].object.values {
            guard let checkout = Checkout(json: c) else { continue }
            out[checkout.metadataId] = .checkedOut(due: checkout.dueDate)
        }
        return (out, holds)
    }

    func availability(_ metadataId: String) async throws -> [CopyAvailability] {
        let json = try await send("GET", "bibs/\(metadataId)/availability", authenticated: false)
        let items = json["entities"]["bibItems"]
        let order = json[path: "availability.items"].strings
        let ids = order.isEmpty ? items.object.keys.sorted() : order
        return ids.compactMap { id in
            let i = items[id]
            guard !i.isNull else { return nil }
            let a = i["availability"]
            return CopyAvailability(
                id: id,
                branch: i["branchName"].nonEmptyString ?? i["branch"]["name"].nonEmptyString ?? "—",
                status: a["libraryStatus"].nonEmptyString ?? a["status"].string?.prettified ?? "",
                isAvailable: a["statusType"].string == "AVAILABLE" || a["group"].string == "AVAILABLE_ITEMS",
                collection: i["collection"].nonEmptyString,
                callNumber: i["callNumber"].nonEmptyString,
                dueDate: i["dueDate"].nonEmptyString)
        }
        .sorted { ($0.isAvailable ? 0 : 1, $0.branch) < ($1.isAvailable ? 0 : 1, $1.branch) }
    }

    /// Full record fields ("Details", "About", …). Opinion/UGC sections are never requested.
    func detailFields(_ metadataId: String) async throws -> [DetailField] {
        let json = try await send("GET", "catalogbibs/\(metadataId)", authenticated: false)
        let record = json["entities"]["catalogBibs"][metadataId]
        // The summary is already shown from the brief record; the title is the header.
        let hidden: Set<String> = ["TITLE", "SUMMARY"]
        var seen = Set<String>()
        return record["fields"].array.flatMap { category in
            category["items"].array.compactMap { item -> DetailField? in
                guard let name = item["fieldName"].string, !hidden.contains(name) else { return nil }
                var values: [String] = []
                for v in item["fieldValues"].array.flatMap({ $0["primary"]["values"].strings }) where !values.contains(v) {
                    values.append(v)
                }
                let field = DetailField(label: name.prettified, values: values)
                guard !values.isEmpty, seen.insert(field.id).inserted else { return nil }
                return field
            }
        }
    }

    func locations() async throws -> [Location] {
        let json = try await send("GET", "locations", query: ["limit": "200"], authenticated: false)
        return json["entities"]["locations"].object.values.compactMap { l in
            guard let id = l["id"].string, let name = l["name"].string, l["isHidden"].bool != true else { return nil }
            return Location(id: id, name: name)
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: Borrowing

    func holds(page: Int, sort: String?) async throws -> ListPage {
        let p = try await login()
        var q = ["accountId": String(p.accountId), "page": String(page)]
        if let sort { q["sort"] = sort }
        let json = try await send("GET", "holds", query: q)
        return borrowingPage(json, listKeys: ["holds"], entityKeys: ["holds"], page: page) { e, bib, idx in
            guard let h = Hold(json: e) else { return nil }
            return ListEntry(id: "hold-\(h.id)", bib: bib ?? Bib(placeholderID: h.metadataId, title: e["bibTitle"].string ?? "Untitled"),
                             kind: .hold(h), serverIndex: idx)
        }
    }

    func checkouts(page: Int, sort: String?) async throws -> ListPage {
        let p = try await login()
        var q = ["accountId": String(p.accountId), "page": String(page)]
        if let sort { q["sort"] = sort }
        let json = try await send("GET", "checkouts", query: q)
        return borrowingPage(json, listKeys: ["checkouts", "checkedout", "checkedOut"], entityKeys: ["checkouts"], page: page) { e, bib, idx in
            guard let c = Checkout(json: e) else { return nil }
            return ListEntry(id: "co-\(c.id)", bib: bib ?? Bib(placeholderID: c.metadataId, title: e["bibTitle"].string ?? "Untitled"),
                             kind: .checkout(c), serverIndex: idx)
        }
    }

    func borrowingHistory(page: Int, sort: String?) async throws -> ListPage {
        let p = try await login()
        var q = ["accountId": String(p.accountId), "page": String(page)]
        if let sort { q["sort"] = sort }
        let json = try await send("GET", "borrowinghistory", query: q)
        return borrowingPage(json, listKeys: ["borrowingHistory", "borrowinghistory"], entityKeys: ["borrowingHistory"], page: page) { e, bib, idx in
            guard let h = HistoryEntry(json: e, fallbackID: "\(page)-\(idx)") else { return nil }
            return ListEntry(id: "bh-\(h.id)", bib: bib ?? Bib(placeholderID: h.metadataId, title: e["bibTitle"].string ?? "Untitled"),
                             kind: .history(h), serverIndex: idx)
        }
    }

    /// Shared parsing for the borrowing endpoints, which all return
    /// `borrowing.<list>.{items, pagination, sortOptions}` plus `entities.<kind>` and `entities.bibs`.
    private func borrowingPage(_ json: JSON, listKeys: [String], entityKeys: [String], page: Int,
                               make: (JSON, Bib?, Int) -> ListEntry?) -> ListPage {
        let borrowing = json["borrowing"]
        let list = listKeys.lazy.map { borrowing[$0] }.first { !$0.isNull }
            ?? borrowing.object.values.first { !$0["items"].isNull } ?? .null
        let entities = entityKeys.lazy.map { json["entities"][$0] }.first { !$0.isNull } ?? .null
        let bibs = json["entities"]["bibs"]
        var ids = list["items"].strings
        if ids.isEmpty { ids = list["results"].strings }
        if ids.isEmpty { ids = list["results"].array.compactMap { $0["id"].string } }
        if ids.isEmpty { ids = entities.object.keys.sorted() }
        let entries = ids.enumerated().compactMap { i, id -> ListEntry? in
            let e = entities[id]
            guard !e.isNull else { return nil }
            let bib = e["metadataId"].string.flatMap { Bib(json: bibs[$0]) }
            return make(e, bib, (page - 1) * 25 + i)
        }
        let sorts = list["sortOptions"].array.compactMap { $0["id"].string ?? $0.string }
        return ListPage(entries: entries,
                        page: list[path: "pagination.page"].int ?? page,
                        pages: list[path: "pagination.pages"].int ?? page,
                        count: list[path: "pagination.count"].int ?? entries.count,
                        pageSize: list[path: "pagination.limit"].int ?? 25,
                        facets: [],
                        sortOptions: sorts,
                        appliedSort: list["sortOptions"].array.first { $0["applied"].bool == true }?["id"].string)
    }

    // MARK: Holds

    func placeHold(_ bib: Bib, pickupBranch: String?) async throws {
        let p = try await login()
        var params: [String: JSON] = ["errorMessageLocale": .string(locale)]
        if let branch = pickupBranch ?? p.preferredPickup { params["branchId"] = .string(branch) }
        let body: JSON = [
            "metadataId": .string(bib.id),
            "materialType": .string(bib.materialType),
            "accountId": .number(Double(p.accountId)),
            "enableSingleClickHolds": false,
            "materialParams": .object(params),
        ]
        let json = try await send("POST", "holds", body: body)
        if let failure = json["failures"][0]["message"].nonEmptyString ?? json[path: "error.message"].nonEmptyString {
            throw BiblioError.unexpected(failure)
        }
    }

    /// Cancels holds and returns the ones the library refused, with its reason
    /// (some libraries don't allow cancelling holds that are ready for pickup).
    @discardableResult
    func cancelHolds(_ holds: [Hold]) async throws -> [(hold: Hold, reason: String)] {
        let p = try await login()
        let body: JSON = [
            "accountId": .number(Double(p.accountId)),
            "holdIds": .array(holds.map { .string($0.id) }),
            "metadataIds": .array(holds.map { .string($0.metadataId) }),
        ]
        let json = try await send("DELETE", "holds", body: body)
        let failures = json["failures"].array
        guard !failures.isEmpty else { return [] }
        var refused: [(Hold, String)] = []
        for f in failures {
            let reason = f["message"].nonEmptyString ?? "The library didn’t cancel this hold."
            let id = f["id"].string ?? f["holdId"].string ?? f["holdsId"].string
            if let id, let hold = holds.first(where: { $0.id == id }) {
                refused.append((hold, reason))
            } else if failures.count == 1, holds.count == 1 {
                refused.append((holds[0], reason))
            } else {
                // Can't tell which hold failed: treat the whole request as refused.
                return holds.map { ($0, reason) }
            }
        }
        return refused
    }

    // MARK: Settings
    //
    // Account settings have no gateway endpoints; they are the Rails forms under
    // /account/* on the library's web host (same session cookies as the gateway login).

    /// Current values as shown on the account settings pages.
    func accountSettings() async throws -> (email: String?, pickup: String?, language: String?) {
        let email = try await accountForm(page: "account/email", action: "/account/contact_information")
        let pickup = try await accountForm(page: "account/pickup_location", action: "/account/preferred_branches")
        let language = try await accountForm(page: "account/language", action: "/account/user_lang")
        return (email.fields["user_email"], pickup.fields["first_preference"], language.fields["user_lang"])
    }

    /// Sets the first preferred pickup location (used for new holds).
    func setDefaultPickupLocation(_ branchId: String) async throws {
        let form = try await accountForm(page: "account/pickup_location", action: "/account/preferred_branches")
        var values = ["first_preference": branchId]
        // A branch can only appear once in the preference list.
        for key in ["second_preference", "third_preference"] where form.fields[key] == branchId { values[key] = "" }
        try await submitAccountForm(form, values: values)
        patron?.preferredPickup = branchId
    }

    func changeLanguage(_ code: String) async throws {
        let form = try await accountForm(page: "account/language", action: "/account/user_lang")
        try await submitAccountForm(form, values: ["user_lang": code])
        setLanguage(code)
    }

    /// Turns the library's record of this account's borrowing history on or off (a gateway
    /// setting, unlike the Rails forms above).
    func setBorrowingHistory(enabled: Bool) async throws {
        let p = try await login()
        _ = try await send("PUT", "accounts/\(p.accountId)/settings/borrowingHistorySetting",
                           body: ["enabled": .bool(enabled)])
        patron?.borrowingHistoryEnabled = enabled
    }

    func changeEmail(_ email: String) async throws {
        let form = try await accountForm(page: "account/email", action: "/account/contact_information")
        try await submitAccountForm(form, values: ["user_email": email])
        patron?.email = email
    }

    /// Changes the PIN/password, then keeps the Keychain in step so automatic re-login still works.
    func changePassword(current: String, new: String) async throws {
        let form = try await accountForm(page: "account/password", action: "/account/change_pin")
        try await submitAccountForm(form, values: ["old_password": current, "new_password": new, "new_password_confirm": new])
        Keychain.setPassword(new, subdomain: subdomain, username: username)
    }

    private func accountForm(page: String, action: String) async throws -> HTMLForm {
        let (html, url) = try await webPage(page)
        guard let form = HTMLForm.forms(in: html, base: url).first(where: { $0.action.path == action }) else {
            throw BiblioError.unexpected("This library’s account settings page could not be read.")
        }
        return form
    }

    private func submitAccountForm(_ form: HTMLForm, values: [String: String]) async throws {
        let (html, status) = try await submitForm(form, values: values)
        guard (200..<400).contains(status) else { throw BiblioError.http(status, nil) }
        if let error = HTMLForm.errorMessage(in: html) { throw BiblioError.unexpected(error) }
    }
}
