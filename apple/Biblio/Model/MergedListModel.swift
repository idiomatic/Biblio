import BiblioCore
import Foundation
import Observation

/// The holds, checked out items, or borrowing history of several logins of one library as one
/// list, interlaced by libbiblio's merge (core/src/list.zig). Each login keeps its own
/// `ItemListModel`, which pages, goes stale, and refetches on its own; this only orders their
/// rows, and forwards sorting and filtering to all of them.
@Observable
final class MergedListModel {
    /// A row of a login's list.
    struct Row: Identifiable, Hashable {
        let login: Int
        let row: ItemListModel.Row
        var id: String { "\(login)/\(row.id)" }
        var entry: ListEntry? { if case .item(let e) = row { e } else { nil } }
    }

    let models: [ItemListModel]
    @ObservationIgnored private let merge: OpaquePointer
    /// The logins shown.
    private(set) var cards: Set<Int>
    /// The lists' sort, which the merge follows (a server sort, once the first page names it).
    var sort: ItemListModel.Sort { models.first?.sort ?? .server("") }

    init(models: [ItemListModel]) {
        self.models = models
        cards = Set(models.indices)
        let pointers = models.map { Optional($0.corePointer) }
        merge = pointers.withUnsafeBufferPointer { biblio_merge_new($0.baseAddress, $0.count) }
    }

    deinit {
        biblio_merge_free(merge)
    }

    /// The merged rows. Reads every login's rows, so views showing them update as pages arrive.
    var rows: [Row] {
        for model in models { _ = model.rows }
        biblio_merge_set_sort(merge, sort.mergeSort)
        var count = 0
        guard let pointer = biblio_merge_rows(merge, &count) else { return [] }
        return UnsafeBufferPointer(start: pointer, count: count).compactMap { r in
            let login = Int(r.login)
            guard let id = r.id else { return Row(login: login, row: .placeholder(Int(r.position))) }
            return models[login].entry(id: String(cString: id)).map { Row(login: login, row: .item($0)) }
        }
    }

    private var shown: [ItemListModel] { models.indices.filter(cards.contains).map { models[$0] } }

    var total: Int { Int(biblio_merge_total(merge)) }
    var isLoading: Bool { shown.contains { $0.isLoading && !$0.loaded } }
    var isBackgroundFetching: Bool { shown.contains(where: \.isBackgroundFetching) }
    var isRefreshing: Bool { shown.contains(where: \.isRefreshing) }
    var loaded: Bool { shown.allSatisfy(\.loaded) }
    var error: String? { shown.compactMap(\.error).first }
    var loadedCount: Int { shown.reduce(0) { $0 + $1.entries.count } }

    /// Loaded entries (any shown login), for empty states.
    var isEmpty: Bool { loaded && loadedCount == 0 }

    var format: String? { models.first?.format }

    var formatChoices: [(value: String, count: Int)] {
        var counts: [String: Int] = [:]
        for model in shown { for c in model.formatChoices { counts[c.value, default: 0] += c.count } }
        return counts.map { ($0.key, $0.value) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
    }

    var serverSorts: [String] { models.first?.serverSorts ?? [] }

    var holdFilter: ItemListModel.HoldFilter? { models.first?.holdFilter }

    func holdCount(_ filter: ItemListModel.HoldFilter) -> Int {
        shown.reduce(0) { $0 + $1.holdCount(filter) }
    }

    func setCards(_ new: Set<Int>) {
        cards = new
        var mask: UInt64 = 0
        for i in new where i < 64 { mask |= 1 << UInt64(i) }
        biblio_merge_set_cards(merge, mask)
    }

    func toggle(_ login: Int) {
        var new = cards
        if new.contains(login) { if new.count > 1 { new.remove(login) } } else { new.insert(login) }
        setCards(new)
    }

    // MARK: Loading

    /// Loads each login's list; the shared throttle paces their requests.
    func loadIfNeeded() {
        for model in models { model.loadIfNeeded() }
    }

    func refresh() async {
        for model in models { await model.refresh() }
    }

    func retry() {
        for model in shown where model.error != nil { model.retry() }
    }

    // MARK: Filtering and sorting

    func setFormat(_ value: String?) {
        for model in models { model.setFormat(value) }
    }

    func setHoldFilter(_ value: ItemListModel.HoldFilter?) {
        for model in models { model.setHoldFilter(value) }
    }

    var isNotBorrowed: Bool { !(models.first?.notBorrowed.isEmpty ?? true) }

    /// Every list hides what any of the cards borrowed before in that format.
    func setNotBorrowed(_ indexes: [BorrowedIndex]) {
        for model in models { model.setNotBorrowed(indexes) }
    }

    func notBorrowedChanged() {
        for model in models { model.notBorrowedChanged() }
    }

    func setSort(_ new: ItemListModel.Sort) {
        guard new != sort else { return }
        for model in models { model.setSort(new) }
    }

    // MARK: Scrolling

    func placeholderAppeared(_ row: Row) {
        guard case .placeholder(let position) = row.row else { return }
        models[row.login].placeholderAppeared(position)
    }

    func placeholderDisappeared(_ row: Row) {
        guard case .placeholder(let position) = row.row else { return }
        models[row.login].placeholderDisappeared(position)
    }

    func itemAppeared(_ row: Row) {
        if let entry = row.entry { models[row.login].itemAppeared(entry) }
    }
}

extension ItemListModel.Sort {
    fileprivate var mergeSort: biblio_list_sort {
        switch self {
        case .server(let id):
            switch id {
            case "due_date": BIBLIO_LIST_SORT_DUE_DATE
            case "status": BIBLIO_LIST_SORT_STATUS
            case "title": BIBLIO_LIST_SORT_SERVER_TITLE
            case "author": BIBLIO_LIST_SORT_AUTHOR
            default: BIBLIO_LIST_SORT_SERVER
            }
        case .peopleWaiting: BIBLIO_LIST_SORT_PEOPLE_WAITING
        case .clientTitle: BIBLIO_LIST_SORT_TITLE
        }
    }
}
