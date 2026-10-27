import Foundation

/// A catalog record ("bib") as it appears in search results, holds, checkouts and history.
nonisolated struct Bib: Identifiable, Hashable, Sendable, Codable {
    var id: String
    var title: String
    var subtitle: String?
    var authors: [String]
    var format: String
    var publicationDate: String?
    var edition: String?
    var callNumber: String?
    var summary: String?
    var jacketSmall: URL?
    var jacketLarge: URL?
    var materialType: String
    var holdable: Bool
    var status: String?
    var heldCopies: Int
    var availableCopies: Int
    var totalCopies: Int
    var onOrderCopies: Int

    /// Builds a bib from a gateway `entities.bibs[id]` value.
    init?(json: JSON) {
        let brief = json["briefInfo"]
        guard let id = json["id"].string ?? brief["metadataId"].string else { return nil }
        self.id = id
        title = brief["title"].nonEmptyString ?? "Untitled"
        subtitle = brief["subtitle"].nonEmptyString
        authors = brief["authors"].strings
        format = brief["format"].string ?? "UNKNOWN"
        publicationDate = brief["publicationDate"].nonEmptyString
        edition = brief["edition"].nonEmptyString
        callNumber = brief["callNumber"].nonEmptyString
        summary = brief["description"].nonEmptyString
        jacketSmall = brief["jacket"]["medium"].string.flatMap(URL.init(string:))
            ?? brief["jacket"]["small"].string.flatMap(URL.init(string:))
        jacketLarge = brief["jacket"]["large"].string.flatMap(URL.init(string:)) ?? jacketSmall
        materialType = json["policy"]["materialType"].string ?? json["availability"]["bibType"].string ?? "PHYSICAL"
        holdable = json["policy"]["holdable"].bool ?? true
        let a = json["availability"]
        status = a["status"].string
        heldCopies = a["heldCopies"].int ?? 0
        availableCopies = a["availableCopies"].int ?? 0
        totalCopies = a["totalCopies"].int ?? 0
        onOrderCopies = a["onOrderCopies"].int ?? 0
    }

    /// Minimal bib for entries whose catalog record was not returned (e.g. old history rows).
    init(placeholderID id: String, title: String) {
        self.id = id
        self.title = title
        authors = []
        format = "UNKNOWN"
        materialType = "PHYSICAL"
        holdable = false
        heldCopies = 0
        availableCopies = 0
        totalCopies = 0
        onOrderCopies = 0
    }

    var fullTitle: String {
        if let subtitle { return "\(title): \(subtitle)" }
        return title
    }

    var primaryAuthor: String? { authors.first }

    /// Publication date as shown in lists: "2026", or a year pulled from "20261006" / "03/23/2027".
    var displayDate: String? {
        guard let d = publicationDate else { return nil }
        if d.count == 4 { return d }
        if d.count == 8, d.allSatisfy(\.isNumber) { return String(d.prefix(4)) }
        if let r = d.range(of: #"\b(1[5-9]|20)\d\d\b"#, options: .regularExpression) { return String(d[r]) }
        return d
    }

    /// Text used when an item is dropped onto a search field.
    var searchText: String {
        [title, primaryAuthor].compactMap { $0 }.joined(separator: " ")
    }
}

/// One row in any item list. `kind` carries the extra data a particular list knows.
nonisolated struct ListEntry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case catalog
        case hold(Hold)
        case checkout(Checkout)
        case history(HistoryEntry)
    }

    var id: String
    var bib: Bib
    var kind: Kind
    /// Position the server returned this row in, used to keep client sorts stable.
    var serverIndex: Int = 0
    /// For catalog rows: whether the signed-in account has this item on hold or checked out.
    var catalogStatus: AccountStatus?
    /// For catalog rows: the account's hold on this item, if any (needed to cancel it).
    var catalogHold: Hold?

    /// The account's hold on this item, whichever list it appears in.
    var hold: Hold? {
        if case .hold(let h) = kind { return h }
        return catalogHold
    }

    /// This account's relationship to the item, whichever list it appears in.
    var accountStatus: AccountStatus? {
        switch kind {
        case .hold(let h): .onHold(ready: h.status == "READY_FOR_PICKUP", position: h.position)
        case .checkout(let c): .checkedOut(due: c.dueDate)
        case .catalog, .history: catalogStatus
        }
    }
}

/// The signed-in account's current relationship to a catalog item.
nonisolated enum AccountStatus: Hashable, Sendable {
    case onHold(ready: Bool, position: Int?)
    case checkedOut(due: String?)
}

nonisolated struct Hold: Hashable, Sendable {
    var id: String
    var metadataId: String
    var status: String
    var position: Int?
    var pickupLocation: String?
    var expiryDate: String?
    var pickupByDate: String?
    var suspendEndDate: String?
    var canCancel: Bool

    init?(json: JSON) {
        guard let id = json["holdsId"].string ?? json["id"].string,
              let metadataId = json["metadataId"].string else { return nil }
        self.id = id
        self.metadataId = metadataId
        status = json["status"].string ?? ""
        let p = json["holdsPosition"].int
        position = (p ?? -1) > 0 ? p : nil
        pickupLocation = json["pickupLocation"]["name"].nonEmptyString
        expiryDate = json["expiryDate"].nonEmptyString
        pickupByDate = json["pickupByDate"].nonEmptyString
        suspendEndDate = json["suspendEndDate"].nonEmptyString
        canCancel = json["actions"].strings.contains("cancel")
    }
}

nonisolated struct Checkout: Hashable, Sendable {
    var id: String
    var metadataId: String
    var status: String?
    var dueDate: String?
    var checkoutDate: String?
    var timesRenewed: Int?

    init?(json: JSON) {
        guard let id = json["checkoutId"].string ?? json["id"].string,
              let metadataId = json["metadataId"].string else { return nil }
        self.id = id
        self.metadataId = metadataId
        status = json["status"].nonEmptyString
        dueDate = json["dueDate"].nonEmptyString
        checkoutDate = json["checkoutDate"].nonEmptyString ?? json["checkedOutDate"].nonEmptyString
        timesRenewed = json["timesRenewed"].int ?? json["renewals"].int
    }
}

nonisolated struct HistoryEntry: Hashable, Sendable {
    var id: String
    var metadataId: String
    var checkoutDate: String?
    var returnedDate: String?

    init?(json: JSON, fallbackID: String) {
        guard let metadataId = json["metadataId"].string ?? json["bibId"].string else { return nil }
        id = json["borrowingHistoryId"].string ?? json["id"].string ?? fallbackID
        self.metadataId = metadataId
        checkoutDate = json["checkedoutDate"].nonEmptyString ?? json["checkoutDate"].nonEmptyString
            ?? json["checkedOutDate"].nonEmptyString
        returnedDate = json["returnedDate"].nonEmptyString ?? json["dateReturned"].nonEmptyString
    }
}

/// A search facet such as FORMAT, with its values and counts.
nonisolated struct Facet: Hashable, Sendable {
    var id: String
    var values: [(value: String, count: Int)]

    static func == (a: Facet, b: Facet) -> Bool {
        a.id == b.id && a.values.map(\.value) == b.values.map(\.value) && a.values.map(\.count) == b.values.map(\.count)
    }

    func hash(into h: inout Hasher) { h.combine(id); h.combine(values.map(\.value)) }
}

/// One page of any list.
nonisolated struct ListPage: Sendable {
    var entries: [ListEntry]
    var page: Int
    var pages: Int
    var count: Int
    /// Items per page as reported by the server (25 on the sites seen so far).
    var pageSize: Int = 25
    var facets: [Facet]
    var sortOptions: [String]
    var appliedSort: String?
}

/// "Availability by location" row.
nonisolated struct CopyAvailability: Identifiable, Hashable, Sendable {
    var id: String
    var branch: String
    var status: String
    var isAvailable: Bool
    var collection: String?
    var callNumber: String?
    var dueDate: String?
    /// Ordered but not yet received (worded "On-Order", "In-Process", "5 on order", …).
    var isOnOrder = false
}

/// A labelled detail field from the full catalog record.
nonisolated struct DetailField: Identifiable, Hashable, Sendable {
    var id: String { label + values.joined() }
    var label: String
    var values: [String]
}

nonisolated struct Location: Identifiable, Hashable, Sendable, Codable {
    var id: String
    var name: String
}

/// The signed-in patron.
nonisolated struct Patron: Hashable, Sendable {
    var userId: Int
    var accountId: Int
    var name: String
    var email: String?
    var language: String
    var barcode: String?
    var preferredPickup: String?
    /// Whether the library keeps this account's borrowing history; nil if it didn't say.
    var borrowingHistoryEnabled: Bool?
}
