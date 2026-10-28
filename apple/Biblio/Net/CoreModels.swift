import BiblioCore
import Foundation

// The app's models built from libbiblio's typed results (core/include/biblio.h). Each copies
// what it needs, so the C result can be freed right after.

nonisolated extension Bib {
    init(_ c: biblio_bib_t) {
        id = string(c.id) ?? ""
        title = string(c.title) ?? ""
        subtitle = string(c.subtitle)
        authors = strings(c.authors, c.authors_count)
        format = string(c.format) ?? "UNKNOWN"
        publicationDate = string(c.publication_date)
        edition = string(c.edition)
        callNumber = string(c.call_number)
        summary = string(c.summary)
        // A malformed jacket URL drops the jacket rather than the whole list.
        jacketSmall = string(c.jacket_small).flatMap(URL.init(string:))
        jacketLarge = string(c.jacket_large).flatMap(URL.init(string:))
        materialType = string(c.material_type) ?? "PHYSICAL"
        holdable = c.holdable
        status = string(c.status)
        heldCopies = Int(c.held_copies)
        availableCopies = Int(c.available_copies)
        totalCopies = Int(c.total_copies)
        onOrderCopies = Int(c.on_order_copies)
    }
}

nonisolated extension Hold {
    init(_ c: biblio_hold_t) {
        self.init(id: string(c.id) ?? "", metadataId: string(c.metadata_id) ?? "", status: string(c.status) ?? "",
                  position: c.has_position ? Int(c.position) : nil, pickupLocation: string(c.pickup_location),
                  expiryDate: string(c.expiry_date), pickupByDate: string(c.pickup_by_date),
                  suspendEndDate: string(c.suspend_end_date), canCancel: c.can_cancel)
    }
}

nonisolated extension Checkout {
    init(_ c: biblio_checkout_t) {
        self.init(id: string(c.id) ?? "", metadataId: string(c.metadata_id) ?? "", status: string(c.status),
                  dueDate: string(c.due_date), checkoutDate: string(c.checkout_date),
                  timesRenewed: c.has_times_renewed ? Int(c.times_renewed) : nil)
    }
}

nonisolated extension HistoryEntry {
    init(_ c: biblio_history_entry_t) {
        self.init(id: string(c.id) ?? "", metadataId: string(c.metadata_id) ?? "",
                  checkoutDate: string(c.checkout_date), returnedDate: string(c.returned_date))
    }
}

nonisolated extension AccountStatus {
    init(_ c: biblio_account_status_t) {
        self = string(c.kind) == "checkedOut"
            ? .checkedOut(due: string(c.due))
            : .onHold(ready: c.ready, position: c.has_position ? Int(c.position) : nil)
    }
}

nonisolated extension ListEntry {
    /// nil for a hold, checkout or history row missing its record.
    init?(_ c: biblio_list_entry_t) {
        let hold = c.hold.map { Hold($0.pointee) }
        let kind: Kind
        switch string(c.kind) {
        case "hold": guard let hold else { return nil }; kind = .hold(hold)
        case "checkout": guard let checkout = c.checkout else { return nil }; kind = .checkout(Checkout(checkout.pointee))
        case "history": guard let history = c.history else { return nil }; kind = .history(HistoryEntry(history.pointee))
        default: kind = .catalog
        }
        let isCatalog = kind == .catalog
        self.init(id: string(c.id) ?? "", bib: Bib(c.bib), kind: kind, serverIndex: Int(c.server_index),
                  catalogStatus: isCatalog ? c.account_status.map { AccountStatus($0.pointee) } : nil,
                  catalogHold: isCatalog ? hold : nil)
    }
}

nonisolated extension ListPage {
    init(_ c: biblio_list_page_t) {
        let facets = buffer(c.facets, c.facets_count).map { f in
            Facet(id: string(f.id) ?? "",
                  values: buffer(f.values, f.values_count).map { (string($0.value) ?? "", Int($0.count)) })
        }
        self.init(entries: buffer(c.entries, c.entries_count).compactMap(ListEntry.init), page: Int(c.page),
                  pages: Int(c.pages), count: Int(c.count), pageSize: Int(c.page_size), facets: facets,
                  sortOptions: strings(c.sort_options, c.sort_options_count), appliedSort: string(c.applied_sort))
    }
}

nonisolated extension CopyAvailability {
    init(_ c: biblio_copy_t) {
        self.init(id: string(c.id) ?? "", branch: string(c.branch) ?? "", status: string(c.status) ?? "",
                  isAvailable: c.is_available, collection: string(c.collection), callNumber: string(c.call_number),
                  dueDate: string(c.due_date), isOnOrder: c.is_on_order)
    }
}

nonisolated extension DetailField {
    init(_ c: biblio_detail_field_t) {
        self.init(label: string(c.label) ?? "", values: strings(c.values, c.values_count))
    }
}

nonisolated extension Location {
    init(_ c: biblio_location_t) {
        self.init(id: string(c.id) ?? "", name: string(c.name) ?? "")
    }
}

nonisolated extension Patron {
    init(_ c: biblio_patron_t) {
        self.init(userId: Int(c.user_id), accountId: Int(c.account_id), name: string(c.name) ?? "",
                  email: string(c.email), language: string(c.language) ?? "", barcode: string(c.barcode),
                  preferredPickup: string(c.preferred_pickup),
                  borrowingHistoryEnabled: c.has_borrowing_history_enabled ? c.borrowing_history_enabled : nil)
    }
}

nonisolated extension LibraryInfo {
    init(_ c: biblio_library_info_t) {
        let labels = buffer(c.labels, c.labels_count).reduce(into: [String: String]()) { d, pair in
            if let key = string(pair.key) { d[key] = string(pair.value) }
        }
        self.init(subdomain: string(c.subdomain) ?? "", name: string(c.name) ?? "", shortName: string(c.short_name),
                  primaryColor: string(c.primary_color), website: string(c.website), labels: labels,
                  languages: strings(c.languages, c.languages_count), users: [])
    }
}

nonisolated extension LibraryDirectory.Entry {
    init(_ c: biblio_directory_entry_t) {
        self.init(name: string(c.name) ?? "", website: string(c.website).flatMap(URL.init(string:)),
                  region: string(c.region), logo: string(c.logo).flatMap(URL.init(string:)))
    }
}
