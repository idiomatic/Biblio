import BiblioCore
import Foundation
import Observation
import SwiftUI

/// A paged, infinitely scrolling list of items from search, new titles, holds,
/// checkouts or borrowing history, with format filtering and sorting.
///
/// The paging, sorting and filtering are libbiblio's item list (core/src/list.zig), shared with
/// the other apps: it says which pages to fetch and which rows to show, and this model fetches
/// those pages and keeps their entries.
///
/// Once the first page reports the total count, every not-yet-fetched item is shown as a
/// placeholder row, so the scroll bar has its final length from the start. Pages are fetched
/// when their placeholders stay on screen briefly — scrolling or dragging the scroll bar
/// anywhere loads just the pages being looked at, not everything before them.
///
/// Server sorts reload from page 1. Client sorts ("People waiting") are not offered by
/// the site, so they fetch the remaining pages in the background and re-sort as each
/// page arrives, animating the reordering.
@Observable
final class ItemListModel {
    enum Source: Hashable {
        case search(SearchQuery)
        case holds, checkouts, history

        var isSearch: Bool { if case .search = self { return true }; return false }

        fileprivate var core: biblio_list_kind {
            switch self {
            case .search: BIBLIO_LIST_SEARCH
            case .holds: BIBLIO_LIST_HOLDS
            case .checkouts: BIBLIO_LIST_CHECKOUTS
            case .history: BIBLIO_LIST_HISTORY
            }
        }
    }

    enum Sort: Hashable {
        case server(String)
        case peopleWaiting
        case clientTitle

        fileprivate var core: biblio_list_sort {
            switch self {
            case .server: BIBLIO_LIST_SORT_SERVER
            case .peopleWaiting: BIBLIO_LIST_SORT_PEOPLE_WAITING
            case .clientTitle: BIBLIO_LIST_SORT_TITLE
            }
        }
    }

    /// A displayed row: a fetched item, or a stand-in for the item at a server position.
    enum Row: Identifiable, Hashable {
        case item(ListEntry)
        case placeholder(Int)

        var id: String {
            switch self {
            case .item(let e): e.id
            case .placeholder(let i): "placeholder-\(i)"
            }
        }
    }

    enum HoldFilter: String, CaseIterable, Identifiable {
        case ready, notReady, onOrder
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ready: "Ready"
            case .notReady: "Not Ready"
            case .onOrder: "On Order"
            }
        }

        fileprivate var core: biblio_hold_filter {
            switch self {
            case .ready: BIBLIO_HOLD_FILTER_READY
            case .notReady: BIBLIO_HOLD_FILTER_NOT_READY
            case .onOrder: BIBLIO_HOLD_FILTER_ON_ORDER
            }
        }
    }

    /// How long placeholders must stay visible before their page is fetched, so dragging
    /// the scroll bar across a long list doesn't request every page it passes.
    static let placeholderDwell: Duration = .milliseconds(300)

    let client: BiblioClient
    var source: Source

    @ObservationIgnored private let list: CoreList
    /// Fetched entries by id; the core list knows their positions.
    @ObservationIgnored private var entriesByID: [String: ListEntry] = [:]
    @ObservationIgnored private var positions: [String: Int] = [:]

    private(set) var rows: [Row] = []
    /// Fetched entries in server order.
    private(set) var entries: [ListEntry] = []
    private(set) var total = 0
    private(set) var loaded = false
    private(set) var isLoading = false
    /// Refetching while the stale rows stay in place, until the first page replaces them.
    private(set) var isRefreshing = false
    private(set) var isBackgroundFetching = false
    private(set) var error: String?
    private(set) var facets: [Facet] = []
    private(set) var serverSorts: [String] = []
    /// The loaded entries' formats with counts, for account lists' format filter.
    private var localFormats: [(value: String, count: Int)] = []

    /// Facet filters for catalog searches, keyed by facet id (e.g. "FORMAT" → "BLURAY").
    private(set) var facetFilters: [String: String] = [:]
    /// Format filter for borrowing lists, applied locally.
    private(set) var localFormat: String?
    /// Hold-status filter for the holds list, applied locally.
    private(set) var holdFilter: HoldFilter?
    private(set) var sort: Sort

    private let defaultSort: String?
    private var backgroundTask: Task<Void, Never>?
    private var firstPageTask: Task<Void, Never>?
    private var dwellTask: Task<Void, Never>?

    init(client: BiblioClient, source: Source, defaultSort: String? = nil) {
        self.client = client
        self.source = source
        self.defaultSort = defaultSort
        list = CoreList(source.core)
        sort = defaultSort.map(Sort.server) ?? .server("")
    }

    var format: String? { source.isSearch ? facetFilters["FORMAT"] : localFormat }

    /// Format choices with counts: the server's FORMAT facet for searches, or the loaded rows' formats otherwise.
    var formatChoices: [(value: String, count: Int)] {
        source.isSearch ? facets.first { $0.id == "FORMAT" }?.values ?? [] : localFormats
    }

    /// How many loaded holds fall under each hold filter.
    func holdCount(_ filter: HoldFilter) -> Int {
        Int(biblio_list_hold_count(list.pointer, filter.core))
    }

    private var generation: UInt64 { biblio_list_state(list.pointer).generation }

    /// A monotonic clock for the list's age.
    private static var now: Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }

    /// Copies the list's state after a call that may have changed it.
    private func syncState() {
        let state = biblio_list_state(list.pointer)
        total = Int(state.total)
        loaded = state.loaded
        isLoading = state.loading
        isRefreshing = state.refreshing
    }

    /// Copies the rows, entries and formats too, after loading, filtering or sorting.
    private func syncContent() {
        syncState()
        var count = 0
        let ids = biblio_list_ids(list.pointer, &count)
        let newEntries = (0..<count).compactMap { ids?[$0].flatMap { entriesByID[String(cString: $0)] } }
        if newEntries.count != entriesByID.count {
            entriesByID = Dictionary(newEntries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        let rowsPointer = biblio_list_rows(list.pointer, &count)
        var newRows: [Row] = []
        newRows.reserveCapacity(count)
        positions = [:]
        for row in UnsafeBufferPointer(start: rowsPointer, count: count) {
            if let id = row.id {
                guard let entry = entriesByID[String(cString: id)] else { continue }
                newRows.append(.item(entry))
                positions[entry.id] = Int(row.position)
            } else {
                newRows.append(.placeholder(Int(row.position)))
            }
        }
        let formats = biblio_list_formats(list.pointer, &count)
        localFormats = UnsafeBufferPointer(start: formats, count: count).map { (String(cString: $0.format), Int($0.count)) }
        if newEntries != entries { entries = newEntries }
        if newRows != rows { rows = newRows }
    }

    // MARK: Loading

    /// Loads a list that hasn't been fetched yet, or refetches one older than 15 minutes.
    func loadIfNeeded() {
        guard !isLoading else { return }
        if !loaded {
            reload()
        } else if biblio_list_is_stale(list.pointer, Self.now) {
            reload(keepingContent: true)
        }
    }

    /// Starts again from the first page. Keeping content leaves the current rows on screen,
    /// stale, until the first page replaces them all at once.
    func reload(keepingContent: Bool = false) {
        backgroundTask?.cancel()
        backgroundTask = nil
        isBackgroundFetching = false
        dwellTask?.cancel()
        error = nil
        if case .search(let q) = source, q.isEmpty {
            biblio_list_clear(list.pointer)
            facets = []
            syncContent()
            return
        }
        let generation = biblio_list_reload(list.pointer, keepingContent)
        syncContent()
        firstPageTask = fetch(page: 1, generation: generation)
    }

    /// Pull to refresh / View > Refresh. Account lists start a fresh session first: the gateway can
    /// keep serving one session a wrong list (checkouts reported empty), and a new session may not.
    func refresh() async {
        if !source.isSearch {
            biblio_list_begin_refresh(list.pointer)
            syncState()
            _ = try? await client.login(force: true)
        }
        reload(keepingContent: true)
        await firstPageTask?.value
    }

    /// Reloads and fetches every page (for short lists like holds, after a change).
    func reloadAll() async {
        reload(keepingContent: true)
        await firstPageTask?.value
        let state = biblio_list_state(list.pointer)
        guard state.loaded, state.pages > 1 else { return }
        for page in 2...state.pages where biblio_list_request(list.pointer, page) {
            await fetch(page: Int(page), generation: state.generation).value
        }
    }

    /// Retries after an error: the first page if nothing loaded, otherwise the visible pages.
    func retry() {
        error = nil
        if loaded { fetchVisiblePlaceholders() } else { reload() }
    }

    /// Fetches a page the core list requested (it is in flight there).
    @discardableResult
    private func fetch(page: Int, generation: UInt64, animated: Bool = false) -> Task<Void, Never> {
        syncState()
        return Task {
            do {
                let result = try await fetch(page: page)
                if animated {
                    withAnimation(.snappy) { apply(result, page: page, generation: generation) }
                } else {
                    apply(result, page: page, generation: generation)
                }
            } catch {
                guard biblio_list_fail(list.pointer, generation, Int64(page)) else { return }
                self.error = error.localizedDescription
                syncContent()
            }
        }
    }

    private func fetch(page: Int) async throws -> ListPage {
        let serverSort: String? = if case .server(let s) = sort, !s.isEmpty { s } else { defaultSort }
        switch source {
        case .search(let q):
            var q = q
            for (k, v) in facetFilters where k != "FORMAT" { q.filters["f_\(k)"] = v }
            return try await client.search(q, page: page, sort: serverSort, format: facetFilters["FORMAT"])
        case .holds:
            return try await client.holds(page: page, sort: serverSort)
        case .checkouts:
            return try await client.checkouts(page: page, sort: serverSort)
        case .history:
            return try await client.borrowingHistory(page: page, sort: serverSort)
        }
    }

    private func apply(_ result: ListPage, page: Int, generation: UInt64) {
        guard generation == self.generation else { return }
        // The first page of a refresh replaces the stale entries.
        if page == 1 && biblio_list_state(list.pointer).refreshing { entriesByID = [:] }
        // An item that moved between pages while fetching is kept at its first position.
        for entry in result.entries where entriesByID[entry.id] == nil { entriesByID[entry.id] = entry }
        let strings = result.entries.flatMap { [$0.id, $0.bib.title, $0.bib.format] }
        Core.withCStrings(strings) { c in
            let items = result.entries.enumerated().map { i, e in
                var ready = false
                var isHold = false
                if case .hold(let h) = e.kind {
                    isHold = true
                    ready = h.status == "READY_FOR_PICKUP"
                }
                return biblio_list_item(id: c[3 * i], title: c[3 * i + 1], format: c[3 * i + 2],
                                        held_copies: Int64(e.bib.heldCopies), server_index: Int64(e.serverIndex),
                                        is_hold: isHold, ready: ready,
                                        on_order: e.bib.status == "ON_ORDER" || e.bib.onOrderCopies > 0)
            }
            _ = biblio_list_apply(list.pointer, generation, Int64(page), items, items.count, Int64(result.count),
                                  Int64(result.pageSize), Self.now)
        }
        if page == 1 || !result.facets.isEmpty { facets = result.facets }
        if !result.sortOptions.isEmpty { serverSorts = result.sortOptions }
        if case .server(let s) = sort, s.isEmpty, let applied = result.appliedSort { sort = .server(applied) }
        syncContent()
        if page == 1, biblio_list_wants_all_pages(list.pointer) { startBackgroundFetch() }
    }

    // MARK: Scrolling

    /// A placeholder scrolled into view: fetch its page if it is still visible shortly after.
    func placeholderAppeared(_ position: Int) {
        biblio_list_placeholder_appeared(list.pointer, Int64(position))
        dwellTask?.cancel()
        dwellTask = Task {
            try? await Task.sleep(for: Self.placeholderDwell)
            guard !Task.isCancelled else { return }
            fetchVisiblePlaceholders()
        }
    }

    func placeholderDisappeared(_ position: Int) {
        biblio_list_placeholder_disappeared(list.pointer, Int64(position))
    }

    /// An item scrolled into view: prefetch the next page when nearing its placeholders.
    func itemAppeared(_ entry: ListEntry) {
        guard let position = positions[entry.id] else { return }
        let page = biblio_list_item_appeared(list.pointer, Int64(position))
        if page > 0 { fetch(page: Int(page), generation: generation) }
    }

    private func fetchVisiblePlaceholders() {
        var pages = [Int64](repeating: 0, count: 64)
        let count = biblio_list_take_visible_requests(list.pointer, &pages, pages.count)
        let generation = generation
        for page in pages.prefix(count) { fetch(page: Int(page), generation: generation) }
    }

    /// Fetches the remaining pages, one at a time, for client sorts and local filters (and
    /// holds, whose filter counts need every hold).
    private func startBackgroundFetch() {
        guard biblio_list_begin_background(list.pointer) else { return }
        let generation = generation
        isBackgroundFetching = true
        backgroundTask = Task {
            defer {
                if generation == self.generation { isBackgroundFetching = false; backgroundTask = nil }
            }
            while generation == self.generation, !Task.isCancelled {
                let page = biblio_list_next_background_page(list.pointer)
                guard page > 0 else { return }
                await fetch(page: Int(page), generation: generation, animated: true).value
                if error != nil {
                    biblio_list_end_background(list.pointer)
                    return
                }
            }
        }
    }

    // MARK: Filtering and sorting

    func setFormat(_ value: String?) {
        if source.isSearch {
            setFacet("FORMAT", value)
        } else {
            withAnimation {
                localFormat = value
                Core.withCStrings([value]) { biblio_list_set_format(list.pointer, $0[0]) }
                syncContent()
            }
            if biblio_list_needs_all_pages(list.pointer) { startBackgroundFetch() }
        }
    }

    func setHoldFilter(_ value: HoldFilter?) {
        withAnimation {
            holdFilter = value
            biblio_list_set_hold_filter(list.pointer, value?.core ?? BIBLIO_HOLD_FILTER_NONE)
            syncContent()
        }
        if biblio_list_needs_all_pages(list.pointer) { startBackgroundFetch() }
    }

    func setFacet(_ id: String, _ value: String?) {
        guard facetFilters[id] != value else { return }
        facetFilters[id] = value
        reload()
    }

    func setSort(_ newSort: Sort) {
        guard newSort != sort else { return }
        withAnimation(.snappy) {
            sort = newSort
            biblio_list_set_sort(list.pointer, newSort.core)
            syncContent()
        }
        switch newSort {
        case .server:
            reload()
        case .peopleWaiting, .clientTitle:
            // Re-sort what is loaded right away, then keep fetching pages in the background.
            startBackgroundFetch()
        }
    }

    func setSource(_ newSource: Source) {
        guard newSource != source else { return }
        source = newSource
        reload()
    }

    /// Updates the account status shown on catalog rows for an item (after placing or cancelling a hold).
    func setAccountStatus(_ status: AccountStatus?, hold: Hold? = nil, for metadataId: String) {
        var changed = false
        for (id, entry) in entriesByID where entry.bib.id == metadataId && entry.kind == .catalog {
            entriesByID[id]?.catalogStatus = status
            entriesByID[id]?.catalogHold = hold
            changed = true
        }
        if changed { withAnimation { syncContent() } }
    }

    /// This account's hold on an item, if this list knows it.
    func hold(for metadataId: String) -> Hold? {
        entries.first { $0.bib.id == metadataId && $0.hold != nil }?.hold
    }

    /// This account's status for an item, if this list knows it.
    func accountStatus(for metadataId: String) -> AccountStatus? {
        entries.first { $0.bib.id == metadataId }?.accountStatus
    }

    func remove(where predicate: (ListEntry) -> Bool) {
        let ids = entries.filter(predicate).map(\.id)
        guard !ids.isEmpty else { return }
        withAnimation {
            Core.withCStrings(ids) { c in
                _ = biblio_list_remove(list.pointer, c, c.count)
            }
            syncContent()
        }
    }
}

/// Owns a core item list, freed with the model.
private nonisolated final class CoreList: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ kind: biblio_list_kind) {
        pointer = biblio_list_new(kind)
    }

    deinit {
        biblio_list_free(pointer)
    }
}
