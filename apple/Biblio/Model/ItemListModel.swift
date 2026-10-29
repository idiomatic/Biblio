import Foundation
import Observation
import SwiftUI

/// A paged, infinitely scrolling list of items from search, new titles, holds,
/// checkouts or borrowing history, with format filtering and sorting.
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
    }

    enum Sort: Hashable {
        case server(String)
        case peopleWaiting
        case clientTitle
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

    /// Caps background fetching for client sorts and local filters, to stay gentle with the
    /// library's servers; long lists (e.g. years of borrowing history) sort their first 1,000.
    static let clientSortPageLimit = 40
    /// How long placeholders must stay visible before their page is fetched, so dragging
    /// the scroll bar across a long list doesn't request every page it passes.
    static let placeholderDwell: Duration = .milliseconds(300)
    /// How long a fetched list is trusted; showing it again after that refetches it.
    static let maxAge: Duration = .seconds(15 * 60)

    let client: BiblioClient
    var source: Source

    /// Items by server position; nil where the page hasn't been fetched yet.
    private var slots: [ListEntry?] = []
    private var positions: [String: Int] = [:]
    private var loadedPages: Set<Int> = []
    private var inFlight: Set<Int> = []
    private var pageSize = 25

    private(set) var rows: [Row] = []
    private(set) var total = 0
    private(set) var isBackgroundFetching = false
    private(set) var error: String?
    private(set) var facets: [Facet] = []
    private(set) var serverSorts: [String] = []
    private(set) var loaded = false
    /// Refetching while the stale rows stay in place, until the first page replaces them.
    private(set) var isRefreshing = false
    /// When the first page was fetched; the list's age.
    private var loadedAt: ContinuousClock.Instant?

    /// Facet filters for catalog searches, keyed by facet id (e.g. "FORMAT" → "BLURAY").
    private(set) var facetFilters: [String: String] = [:]
    /// Format filter for borrowing lists, applied locally.
    private(set) var localFormat: String?
    /// Hold-status filter for the holds list, applied locally.
    private(set) var holdFilter: HoldFilter?

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

        func matches(_ entry: ListEntry) -> Bool {
            guard case .hold(let h) = entry.kind else { return false }
            let ready = h.status == "READY_FOR_PICKUP"
            switch self {
            case .ready: return ready
            case .notReady: return !ready
            // Waiting on copies the library hasn't received yet.
            case .onOrder: return !ready && (entry.bib.status == "ON_ORDER" || entry.bib.onOrderCopies > 0)
            }
        }
    }

    /// Whether a local (client-side) filter is narrowing an account list.
    private var hasLocalFilter: Bool { !source.isSearch && (localFormat != nil || holdFilter != nil) }

    private func passesLocalFilters(_ e: ListEntry) -> Bool {
        if let localFormat, e.bib.format != localFormat { return false }
        if let holdFilter, !holdFilter.matches(e) { return false }
        return true
    }

    /// How many loaded holds fall under each hold filter.
    func holdCount(_ filter: HoldFilter) -> Int {
        entries.filter { filter.matches($0) && (localFormat == nil || $0.bib.format == localFormat) }.count
    }
    private(set) var sort: Sort

    private let defaultSort: String?
    private var generation = 0
    private var backgroundTask: Task<Void, Never>?
    private var firstPageTask: Task<Void, Never>?
    private var dwellTask: Task<Void, Never>?
    private var visiblePlaceholders: [Int: Int] = [:]   // page → visible placeholder count

    init(client: BiblioClient, source: Source, defaultSort: String? = nil) {
        self.client = client
        self.source = source
        self.defaultSort = defaultSort
        sort = defaultSort.map(Sort.server) ?? .server("")
    }

    var entries: [ListEntry] { slots.compactMap { $0 } }
    var isLoading: Bool { !inFlight.isEmpty }
    var pages: Int { max(1, (total + pageSize - 1) / pageSize) }
    var hasMore: Bool { !loaded || loadedPages.count < pages }

    var format: String? { source.isSearch ? facetFilters["FORMAT"] : localFormat }

    /// Format choices with counts: the server's FORMAT facet for searches, or the loaded rows' formats otherwise.
    var formatChoices: [(value: String, count: Int)] {
        if source.isSearch { return facets.first { $0.id == "FORMAT" }?.values ?? [] }
        var counts: [String: Int] = [:]
        for e in entries { counts[e.bib.format, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    private func page(ofPosition i: Int) -> Int { i / pageSize + 1 }

    /// Rebuilds `rows` after loading, filtering or sorting.
    private func rebuildRows() {
        // The stale rows stay until the first page arrives.
        guard !isRefreshing else { return }
        if hasLocalFilter {
            // A local filter can't know which unfetched items match, so no placeholders.
            rows = sorted(entries.filter(passesLocalFilters)).map(Row.item)
            return
        }
        switch sort {
        case .server:
            var out: [Row] = []
            out.reserveCapacity(slots.count)
            for (i, slot) in slots.enumerated() {
                if let slot { out.append(.item(slot)) }
                else if !loadedPages.contains(page(ofPosition: i)) { out.append(.placeholder(i)) }
                // A short page from the server leaves gaps that are simply skipped.
            }
            rows = out
        case .peopleWaiting, .clientTitle:
            // Sorted items first; the unfetched remainder keeps the scroll bar's length.
            let pending = slots.indices.filter { slots[$0] == nil && !loadedPages.contains(page(ofPosition: $0)) }
            rows = sorted(entries).map(Row.item) + pending.map(Row.placeholder)
        }
    }

    private func sorted(_ items: [ListEntry]) -> [ListEntry] {
        switch sort {
        case .peopleWaiting:
            items.sorted { ($0.bib.heldCopies, -$0.serverIndex) > ($1.bib.heldCopies, -$1.serverIndex) }
        case .clientTitle:
            items.sorted { $0.bib.title.localizedStandardCompare($1.bib.title) == .orderedAscending }
        case .server:
            items
        }
    }

    // MARK: Loading

    /// Loads a list that hasn't been fetched yet, or refetches one older than `maxAge`.
    func loadIfNeeded() {
        guard !isLoading else { return }
        if !loaded { reload() } else if isStale { reload(keepingContent: true) }
    }

    var isStale: Bool {
        loadedAt.map { ContinuousClock.now - $0 > Self.maxAge } ?? false
    }

    /// Starts again from the first page. Keeping content leaves the current rows on screen,
    /// stale, until the first page replaces them all at once.
    func reload(keepingContent: Bool = false) {
        generation += 1
        backgroundTask?.cancel()
        backgroundTask = nil
        dwellTask?.cancel()
        loadedPages = []
        inFlight = []
        visiblePlaceholders = [:]
        error = nil
        isRefreshing = keepingContent && loaded
        if !isRefreshing { clearContent() }
        if case .search(let q) = source, q.isEmpty {
            clearContent()
            isRefreshing = false
            facets = []
            return
        }
        firstPageTask = request(page: 1)
    }

    private func clearContent() {
        slots = []
        positions = [:]
        rows = []
        total = 0
        loaded = false
        loadedAt = nil
    }

    /// Pull to refresh / View > Refresh. Account lists start a fresh session first: the gateway can
    /// keep serving one session a wrong list (checkouts reported empty), and a new session may not.
    func refresh() async {
        if !source.isSearch {
            isRefreshing = loaded
            _ = try? await client.login(force: true)
        }
        reload(keepingContent: true)
        await firstPageTask?.value
    }

    /// Reloads and fetches every page (for short lists like holds, after a change).
    func reloadAll() async {
        reload(keepingContent: true)
        await firstPageTask?.value
        guard loaded else { return }
        for p in 2...max(2, pages) where p <= pages {
            await request(page: p)?.value
        }
    }

    /// Retries after an error: the first page if nothing loaded, otherwise the visible pages.
    func retry() {
        error = nil
        if loaded { fetchVisiblePlaceholders() } else { reload() }
    }

    @discardableResult
    private func request(page: Int, animated: Bool = false) -> Task<Void, Never>? {
        guard page >= 1, !loadedPages.contains(page), !inFlight.contains(page) else { return nil }
        guard page == 1 || (page <= pages && !isRefreshing) else { return nil }
        let gen = generation
        inFlight.insert(page)
        return Task {
            defer { if gen == generation { inFlight.remove(page) } }
            do {
                let result = try await fetch(page: page)
                guard gen == generation else { return }
                if animated { withAnimation(.snappy) { apply(result, page: page) } } else { apply(result, page: page) }
                // Holds lists are short and their filter counts need every hold, so load them all.
                if page == 1, needsAllPages || source == .holds { startBackgroundFetch() }
            } catch {
                guard gen == generation else { return }
                if isRefreshing {
                    // Nothing left to retry from: the stale rows go, and the error shows instead.
                    isRefreshing = false
                    clearContent()
                }
                self.error = error.localizedDescription
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

    private func apply(_ result: ListPage, page: Int) {
        if page == 1 {
            if isRefreshing {
                slots = []
                positions = [:]
                isRefreshing = false
            }
            pageSize = max(result.pageSize, 1)
            loadedAt = .now
        }
        total = result.count
        // Size the list to the reported total (it may change between pages if the data does).
        let size = max(result.count, (page - 1) * pageSize + result.entries.count)
        if slots.count < size {
            slots.append(contentsOf: Array(repeating: nil, count: size - slots.count))
        } else if slots.count > size {
            for e in slots[size...].compactMap({ $0 }) { positions[e.id] = nil }
            slots.removeLast(slots.count - size)
        }
        let start = (page - 1) * pageSize
        for (offset, entry) in result.entries.enumerated() where start + offset < slots.count {
            // An item that moved between pages while fetching is kept at its first position.
            guard positions[entry.id] == nil else { continue }
            slots[start + offset] = entry
            positions[entry.id] = start + offset
        }
        loadedPages.insert(page)
        loaded = true
        if page == 1 || !result.facets.isEmpty { facets = result.facets }
        if !result.sortOptions.isEmpty { serverSorts = result.sortOptions }
        if case .server(let s) = sort, s.isEmpty, let applied = result.appliedSort { sort = .server(applied) }
        rebuildRows()
    }

    // MARK: Scrolling

    /// A placeholder scrolled into view: fetch its page if it is still visible shortly after.
    func placeholderAppeared(_ position: Int) {
        visiblePlaceholders[page(ofPosition: position), default: 0] += 1
        dwellTask?.cancel()
        dwellTask = Task {
            try? await Task.sleep(for: Self.placeholderDwell)
            guard !Task.isCancelled else { return }
            fetchVisiblePlaceholders()
        }
    }

    func placeholderDisappeared(_ position: Int) {
        let p = page(ofPosition: position)
        guard let n = visiblePlaceholders[p] else { return }
        visiblePlaceholders[p] = n > 1 ? n - 1 : nil
    }

    /// An item scrolled into view: prefetch the next page when nearing its placeholders.
    func itemAppeared(_ entry: ListEntry) {
        guard case .server = sort, let i = positions[entry.id] else { return }
        let ahead = page(ofPosition: i + pageSize / 2)
        if ahead <= pages, !loadedPages.contains(ahead) { request(page: ahead) }
    }

    private func fetchVisiblePlaceholders() {
        for p in visiblePlaceholders.keys.sorted() { request(page: p) }
    }

    /// Client sorts and local filters are only correct once every page is loaded.
    private var needsAllPages: Bool {
        switch sort {
        case .peopleWaiting, .clientTitle: return true
        case .server: return hasLocalFilter
        }
    }

    private func startBackgroundFetch() {
        guard backgroundTask == nil, loaded, hasMore, !isRefreshing else { return }
        let gen = generation
        let last = min(pages, Self.clientSortPageLimit)
        isBackgroundFetching = true
        backgroundTask = Task {
            defer {
                if gen == generation { isBackgroundFetching = false; backgroundTask = nil }
            }
            for p in 1...last where !loadedPages.contains(p) {
                guard gen == generation, !Task.isCancelled else { return }
                if let task = request(page: p, animated: true) { await task.value }
                if error != nil { return }
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
                rebuildRows()
            }
            if needsAllPages { startBackgroundFetch() }
        }
    }

    func setHoldFilter(_ value: HoldFilter?) {
        withAnimation {
            holdFilter = value
            rebuildRows()
        }
        if needsAllPages { startBackgroundFetch() }
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
            rebuildRows()
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
        for i in slots.indices where slots[i]?.bib.id == metadataId && slots[i]?.kind == .catalog {
            slots[i]?.catalogStatus = status
            slots[i]?.catalogHold = hold
            changed = true
        }
        if changed { withAnimation { rebuildRows() } }
    }

    /// This account's hold on an item, if this list knows it.
    func hold(for metadataId: String) -> Hold? {
        slots.lazy.compactMap { $0 }.first { $0.bib.id == metadataId && $0.hold != nil }?.hold
    }

    /// This account's status for an item, if this list knows it.
    func accountStatus(for metadataId: String) -> AccountStatus? {
        slots.lazy.compactMap { $0 }.first { $0.bib.id == metadataId }?.accountStatus
    }

    func remove(where predicate: (ListEntry) -> Bool) {
        withAnimation {
            let before = slots.count
            slots.removeAll { $0.map(predicate) ?? false }
            total = max(0, total - (before - slots.count))
            positions = Dictionary(uniqueKeysWithValues: slots.enumerated().compactMap { i, e in e.map { ($0.id, i) } })
            rebuildRows()
        }
    }
}
