import Foundation
import Observation

/// Keeps one client per (library, user) and lets only one window use a login at a time.
/// BiblioCommons ends a session when the same login signs in elsewhere, so two windows on
/// one login would keep evicting each other. Guest windows have no login and are unlimited.
@Observable
final class ClientPool {
    static let shared = ClientPool()
    @ObservationIgnored private var clients: [String: BiblioClient] = [:]
    /// Login key → the window currently using it.
    private var owners: [String: UUID] = [:]

    private func key(_ subdomain: String, _ username: String) -> String { "\(subdomain)|\(username)" }

    func client(subdomain: String, username: String) -> BiblioClient {
        let key = key(subdomain, username)
        if let c = clients[key] { return c }
        let c = BiblioClient(subdomain: subdomain, username: username)
        clients[key] = c
        return c
    }

    func discard(subdomain: String, username: String) {
        clients[key(subdomain, username)] = nil
    }

    func isInUse(subdomain: String, username: String) -> Bool {
        !username.isEmpty && owners[key(subdomain, username)] != nil
    }

    /// Reserves a login for a window. Fails if another window already uses it.
    func claim(subdomain: String, username: String, window: UUID) -> Bool {
        guard !username.isEmpty else { return true }
        let key = key(subdomain, username)
        if let owner = owners[key], owner != window { return false }
        owners[key] = window
        return true
    }

    func release(subdomain: String, username: String, window: UUID) {
        let key = key(subdomain, username)
        if owners[key] == window { owners[key] = nil }
    }
}

nonisolated enum AppSection: String, Hashable, CaseIterable, Identifiable, Codable {
    case search, newTitles, holds, checkouts, history, account
    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: "Search"
        case .newTitles: "New Titles"
        case .holds: "Holds"
        case .checkouts: "Checked Out"
        case .history: "Borrowing History"
        case .account: "Account"
        }
    }

    var systemImage: String {
        switch self {
        case .search: "magnifyingglass"
        case .newTitles: "sparkles"
        case .holds: "tray.and.arrow.down"
        case .checkouts: "books.vertical"
        case .history: "clock.arrow.circlepath"
        case .account: "person.crop.circle"
        }
    }
}

/// Everything one window shows: its signed-in patron and its own lists.
@Observable
final class WindowSession {
    let library: LibraryInfo
    /// Empty for a guest window, which browses the catalog without signing in.
    let username: String
    let client: BiblioClient

    var patron: Patron?
    var loginError: String?
    var section: AppSection? = .search
    var selection: Bib?
    /// All selected rows when more than one is selected (the inspector then shows bulk actions).
    var selectedEntries: [ListEntry] = []
    var showInspector = false
    var searchText = ""
    var banner: Banner?
    /// Shows the login picker, so a guest can sign in without leaving the window.
    var showingSignIn = false
    /// On iPhone the item sheet closes for the login picker; this reopens it afterwards.
    var reopenInspector = false

    let searchList: ItemListModel
    let newTitlesList: ItemListModel
    let holdsList: ItemListModel
    let checkoutsList: ItemListModel
    let historyList: ItemListModel
    var locations: [Location] = []

    struct Banner: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var isError: Bool
    }

    init(library: LibraryInfo, username: String) {
        self.library = library
        self.username = username
        let client = ClientPool.shared.client(subdomain: library.subdomain, username: username)
        self.client = client
        searchList = ItemListModel(client: client, source: .search(SearchQuery(query: "")))
        newTitlesList = ItemListModel(client: client, source: .search(.newTitles(onOrder: false)), defaultSort: "newly_acquired")
        holdsList = ItemListModel(client: client, source: .holds)
        checkoutsList = ItemListModel(client: client, source: .checkouts)
        historyList = ItemListModel(client: client, source: .history)
    }

    var isGuest: Bool { username.isEmpty }
    var displayName: String { isGuest ? "Guest" : patron?.name ?? username }

    func start() async {
        if isGuest {
            if locations.isEmpty { locations = (try? await client.locations()) ?? [] }
            return
        }
        do {
            patron = try await client.login()
            loginError = nil
            // Fill the sidebar's hold and checkout counts without waiting for those lists to be opened.
            holdsList.loadIfNeeded()
            checkoutsList.loadIfNeeded()
            if locations.isEmpty { locations = (try? await client.locations()) ?? [] }
        } catch {
            loginError = error.localizedDescription
        }
    }

    func list(for section: AppSection) -> ItemListModel? {
        switch section {
        case .search: searchList
        case .newTitles: newTitlesList
        case .holds: holdsList
        case .checkouts: checkoutsList
        case .history: historyList
        case .account: nil
        }
    }

    func runSearch(_ text: String, searchType: String = "smart") {
        searchText = text
        section = .search
        searchList.source = .search(SearchQuery(query: text, searchType: searchType))
        searchList.reload()
    }

    /// Carries what a guest was looking at over to the session they signed in to.
    func continueBrowsing(from guest: WindowSession) {
        searchText = guest.searchText
        searchList.source = guest.searchList.source
        section = guest.section
        selection = guest.selection
        showInspector = guest.showInspector || guest.reopenInspector
        locations = guest.locations
    }

    func requestSignIn() {
        reopenInspector = showInspector
        showingSignIn = true
    }

    /// After the login picker closes without signing in.
    func signInDismissed() {
        if reopenInspector { showInspector = true }
        reopenInspector = false
    }

    func select(_ bib: Bib) {
        selection = bib
        selectedEntries = []
        showInspector = true
    }

    func placeHold(_ bib: Bib, pickup: String? = nil) async {
        guard !isGuest else {
            requestSignIn()
            return
        }
        do {
            try await client.placeHold(bib, pickupBranch: pickup)
            show("Hold placed on “\(bib.title)”.")
            for list in [searchList, newTitlesList] {
                list.setAccountStatus(.onHold(ready: false, position: nil), for: bib.id)
            }
            // Load the whole (short) holds list so the new hold can be found and cancelled.
            Task { await holdsList.reloadAll() }
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    func placeHold(_ transfer: BibTransfer) async {
        guard transfer.subdomain == library.subdomain else {
            show("“\(transfer.title)” belongs to a different library.", isError: true)
            return
        }
        await placeHold(transfer.bib)
    }

    /// Selection from a list: one row shows its details; several show bulk actions.
    func select(entries: [ListEntry]) {
        guard !entries.isEmpty else { return }
        if entries.count == 1 {
            select(entries[0].bib)
        } else {
            selectedEntries = entries
            showInspector = true
        }
    }

    /// Places holds on several items, one at a time, and reports the outcome in one banner.
    func placeHolds(_ bibs: [Bib]) async {
        guard !isGuest else { requestSignIn(); return }
        var placed = 0
        var firstError: String?
        for bib in bibs {
            do {
                try await client.placeHold(bib, pickupBranch: nil)
                placed += 1
                for list in [searchList, newTitlesList] {
                    list.setAccountStatus(.onHold(ready: false, position: nil), for: bib.id)
                }
            } catch {
                firstError = firstError ?? error.localizedDescription
                // The library refuses everything after its hold limit; stop asking.
                if error.localizedDescription.localizedCaseInsensitiveContains("maximum") { break }
            }
        }
        if let firstError {
            show("Placed \(placed) of \(bibs.count) holds. \(firstError)", isError: true)
        } else {
            show(placed == 1 ? "Hold placed." : "\(placed) holds placed.")
        }
        if placed > 0 { Task { await holdsList.reloadAll() } }
    }

    func cancel(_ requested: [Hold]) async {
        do {
            let refused = try await client.cancelHolds(requested)
            let refusedIDs = Set(refused.map(\.hold.id))
            let holds = requested.filter { !refusedIDs.contains($0.id) }
            if let reason = refused.first?.reason {
                show(holds.isEmpty ? reason : "Cancelled \(holds.count) of \(requested.count) holds. \(reason)", isError: true)
            } else {
                show(holds.count == 1 ? "Hold cancelled." : "\(holds.count) holds cancelled.")
            }
            for hold in holds {
                for list in [searchList, newTitlesList] { list.setAccountStatus(nil, for: hold.metadataId) }
            }
            holdsList.remove { entry in
                if case .hold(let h) = entry.kind { return holds.contains(h) }
                return false
            }
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    /// This account's hold on an item, from whichever of this window's lists knows it.
    func hold(for metadataId: String) -> Hold? {
        for list in [holdsList, searchList, newTitlesList] {
            if let hold = list.hold(for: metadataId) { return hold }
        }
        return nil
    }

    /// This account's status for an item, from whichever of this window's lists knows it.
    func accountStatus(for metadataId: String) -> AccountStatus? {
        for list in [checkoutsList, holdsList, searchList, newTitlesList] {
            if let status = list.accountStatus(for: metadataId) { return status }
        }
        return nil
    }

    func show(_ message: String, isError: Bool = false) {
        banner = Banner(message: message, isError: isError)
    }

    func refreshPatron() async {
        patron = await client.patron
    }
}
