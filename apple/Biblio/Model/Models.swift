import Foundation

/// A catalog record ("bib") as it appears in search results, holds, checkouts and history.
/// Parsed from the gateway by libbiblio (core/src/models.zig); see CoreModels.swift.
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
    /// The library's own format code; `format` may refine it (4K filed as Blu-ray).
    var libraryFormat: String

    private enum CodingKeys: String, CodingKey {
        case id, title, subtitle, authors, format, publicationDate, edition, callNumber, summary
        case jacketSmall, jacketLarge, materialType, holdable, status
        case heldCopies, availableCopies, totalCopies, onOrderCopies, libraryFormat
    }

    /// Decodes a bib from a drag-and-drop transfer. A malformed jacket URL
    /// drops the jacket rather than the whole list.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        authors = try c.decodeIfPresent([String].self, forKey: .authors) ?? []
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? "UNKNOWN"
        publicationDate = try c.decodeIfPresent(String.self, forKey: .publicationDate)
        edition = try c.decodeIfPresent(String.self, forKey: .edition)
        callNumber = try c.decodeIfPresent(String.self, forKey: .callNumber)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        jacketSmall = (try? c.decodeIfPresent(String.self, forKey: .jacketSmall)).flatMap { $0 }.flatMap(URL.init(string:))
        jacketLarge = (try? c.decodeIfPresent(String.self, forKey: .jacketLarge)).flatMap { $0 }.flatMap(URL.init(string:))
        materialType = try c.decodeIfPresent(String.self, forKey: .materialType) ?? "PHYSICAL"
        holdable = try c.decodeIfPresent(Bool.self, forKey: .holdable) ?? false
        status = try c.decodeIfPresent(String.self, forKey: .status)
        heldCopies = try c.decodeIfPresent(Int.self, forKey: .heldCopies) ?? 0
        availableCopies = try c.decodeIfPresent(Int.self, forKey: .availableCopies) ?? 0
        totalCopies = try c.decodeIfPresent(Int.self, forKey: .totalCopies) ?? 0
        onOrderCopies = try c.decodeIfPresent(Int.self, forKey: .onOrderCopies) ?? 0
        libraryFormat = try c.decodeIfPresent(String.self, forKey: .libraryFormat) ?? format
    }

    var fullTitle: String {
        if let subtitle { return "\(title): \(subtitle)" }
        return title
    }

    var primaryAuthor: String? { authors.first }

    /// Text used when an item is dropped onto a search field.
    var searchText: String {
        [title, primaryAuthor].compactMap { $0 }.joined(separator: " ")
    }
}

/// A localized message for text that isn't a SwiftUI `Text` (banners, errors), with its
/// `^[…](inflect: true)` counts made to agree, as `Text` does.
nonisolated func inflected(_ value: String.LocalizationValue) -> String {
    String(AttributedString(localized: value).characters)
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
        case .hold(let h): .onHold(ready: h.isReady, position: h.position)
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
}

nonisolated struct Checkout: Hashable, Sendable {
    var id: String
    var metadataId: String
    var status: String?
    var dueDate: String?
    var checkoutDate: String?
    var timesRenewed: Int?
}

nonisolated struct HistoryEntry: Hashable, Sendable {
    var id: String
    var metadataId: String
    var checkoutDate: String?
    var returnedDate: String?
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
    /// The status grouped by the core from the library's own wording.
    var kind: CopyKind = .other
}

/// A labeled detail field from the full catalog record.
nonisolated struct DetailField: Identifiable, Hashable, Sendable {
    var id: String { label + values.joined() }
    var label: String
    var values: [String]
    /// The record's edition statement, whatever the library's language calls it.
    var isEdition = false
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
    /// The first name in the library's contact record for the account, if it has one.
    var firstName: String? = nil
}
