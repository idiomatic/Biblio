import Foundation
import Observation
import SwiftUI

/// What tells one card from another in a combined window: a color and a monogram, by default
/// from its place among the library's cards and the patron's first initial, or as chosen.
struct CardStyle {
    var color: Color
    var monogram: String

    static let palette: [Color] = [.blue, .orange, .purple, .teal, .pink, .green, .indigo, .brown]

    init(index: Int, name: String, look: CardLook = CardLook()) {
        color = Self.palette[(look.color ?? index) % Self.palette.count]
        monogram = look.monogram.flatMap { $0.isEmpty ? nil : $0 }
            ?? name.first(where: \.isLetter).map { String($0).uppercased() } ?? "?"
    }

    /// The style of a library's card as the user has set it.
    static func of(library: LibraryInfo, username: String, name: String) -> CardStyle {
        let index = library.users.firstIndex(of: username) ?? 0
        return CardStyle(index: index, name: name, look: LibraryStore.shared.look(subdomain: library.subdomain, username: username))
    }
}

/// A window that shows all of one library's logins together: each login keeps its own session
/// (client, lists, banner), and the holds, checked out items, and history interlace.
/// Catalog sections use the first login's session.
@Observable
final class CombinedSession {
    let library: LibraryInfo
    let sessions: [WindowSession]
    var windowActions: WindowSession.WindowActions?
    /// The card last used in this window (a row opened, a hold placed, an account page shown);
    /// the library card follows it, as does the Lock Screen control.
    var lastUsed = 0 {
        didSet {
            guard lastUsed != oldValue, sessions.indices.contains(lastUsed) else { return }
            LibraryStore.shared.noteLogin(subdomain: library.subdomain, username: sessions[lastUsed].username)
        }
    }

    /// The session of the card last used.
    var cardSession: WindowSession { sessions[min(lastUsed, sessions.count - 1)] }

    var section: AppSection? = .holds {
        didSet {
            guard section != oldValue else { return }
            if case .account(let user)? = section, let i = sessions.firstIndex(where: { $0.username == user }) { lastUsed = i }
            for s in sessions { s.showInspector = false; s.selection = nil }
        }
    }
    /// The login whose item the inspector shows, in the account sections.
    var selectedLogin = 0

    let holds: MergedListModel
    let checkouts: MergedListModel
    let history: MergedListModel

    init(library: LibraryInfo, sessions: [WindowSession]) {
        self.library = library
        self.sessions = sessions
        holds = MergedListModel(models: sessions.map(\.holdsList))
        checkouts = MergedListModel(models: sessions.map(\.checkoutsList))
        history = MergedListModel(models: sessions.map(\.historyList))
        // A search from an item's author link, or a drop on the search field, shows the results.
        for session in sessions {
            session.searchRouter = { [weak self] text, type in
                guard let self else { return }
                primary.performSearch(text, searchType: type)
                section = .search
            }
        }
    }

    var primary: WindowSession { sessions[0] }

    /// The session the inspector, banner, and catalog act on.
    var active: WindowSession {
        switch section ?? .holds {
        case .search, .newTitles: primary
        default: sessions[min(selectedLogin, sessions.count - 1)]
        }
    }

    /// The card the last hold was placed for in this window; "For:" starts there.
    var stickyCard: Int? {
        didSet { if let stickyCard { lastUsed = stickyCard } }
    }

    /// The cards that can still hold an item: those with no hold or checkout of it.
    func cardsAbleToHold(_ bib: Bib) -> [Int] {
        sessions.indices.filter { sessions[$0].accountStatus(for: bib.id) == nil }
    }

    /// The card a hold on `bib` is for: the sticky choice if it can hold it, else the card with
    /// the fewest holds.
    func cardForHold(_ bib: Bib) -> Int? {
        let able = cardsAbleToHold(bib)
        if let stickyCard, able.contains(stickyCard) { return stickyCard }
        return able.min { sessions[$0].holdsList.total < sessions[$1].holdsList.total }
    }

    /// Which card or cards a batch of holds is for.
    enum HoldTarget: Hashable {
        /// Every title on this card.
        case card(Int)
        /// Each title on its own default card (the sticky choice, else the card with the fewest holds).
        case auto
        /// Balanced across the cards, the one with the fewest holds first; a card that reaches
        /// its hold limit passes the rest to the others.
        case split
        /// Each title on the card it was given (title id → card).
        case assigned([String: Int])
    }

    /// Places holds for `target`, one request at a time, and reports the outcome in one banner,
    /// naming the card of each refusal.
    func placeHolds(_ bibs: [Bib], target: HoldTarget) async {
        var placed: [Int: Int] = [:]
        var refusals: [String] = []
        var full: Set<Int> = []
        var skipped = 0
        var counts = sessions.map { $0.holdsList.total }
        for bib in bibs {
            let able = cardsAbleToHold(bib).filter { !full.contains($0) }
            let candidates: [Int]
            switch target {
            case .card(let c): candidates = able.contains(c) ? [c] : []
            case .auto: candidates = cardForHold(bib).map { able.contains($0) ? [$0] : [] } ?? []
            case .assigned(let cards): candidates = cards[bib.id].map { able.contains($0) ? [$0] : [] } ?? []
            case .split: candidates = able.sorted { counts[$0] != counts[$1] ? counts[$0] < counts[$1] : $0 < $1 }
            }
            if candidates.isEmpty && full.isEmpty { skipped += 1 }
            for c in candidates {
                do {
                    try await sessions[c].client.placeHold(bib, pickupBranch: nil)
                    placed[c, default: 0] += 1
                    counts[c] += 1
                    // Only the card that placed it holds it.
                    for list in [sessions[c].searchList, sessions[c].newTitlesList] {
                        list.setAccountStatus(.onHold(ready: false, position: nil), for: bib.id)
                    }
                    break
                } catch {
                    // A server error after the library placed the hold still counts.
                    if await sessions[c].holdPlacedDespite(error, bib) {
                        placed[c, default: 0] += 1
                        counts[c] += 1
                        for list in [sessions[c].searchList, sessions[c].newTitlesList] {
                            list.setAccountStatus(.onHold(ready: false, position: nil), for: bib.id)
                        }
                        break
                    }
                    let message = "\(name(c))’s card: \(error.localizedDescription)"
                    if !refusals.contains(message) { refusals.append(message) }
                    // The library refuses everything after its hold limit; stop asking that card.
                    if error.localizedDescription.localizedCaseInsensitiveContains("maximum") { full.insert(c) }
                }
            }
        }
        let total = placed.values.reduce(0, +)
        let by = placed.sorted { $0.key < $1.key }.map { "\(name($0.key)) \($0.value)" }.joined(separator: ", ")
        let skippedNote = skipped == 0 ? "" : " \(skipped) skipped: that card already has them."
        if refusals.isEmpty {
            let placedText = total == 1 ? "Hold placed (\(by))." : "\(total) holds placed (\(by))."
            primary.show(total == 0 ? "No holds placed.\(skippedNote)" : placedText + skippedNote, isError: total == 0)
        } else {
            primary.show("Placed \(total) of \(bibs.count) holds\(total > 0 ? " (\(by))" : ""). \(refusals.joined(separator: " "))\(skippedNote)", isError: true)
        }
        for (c, _) in placed { Task { await sessions[c].holdsList.reloadAll() } }
    }

    func list(for section: AppSection) -> MergedListModel? {
        switch section {
        case .holds: holds
        case .checkouts: checkouts
        case .history: history
        default: nil
        }
    }

    func style(_ login: Int) -> CardStyle {
        CardStyle.of(library: library, username: sessions[login].username,
                     name: sessions[login].patron?.name ?? sessions[login].username)
    }

    /// What the card is called here: the user's own name for it, or the account holder's first name.
    func name(_ login: Int) -> String { sessions[login].callName }

    /// Starts every login; the shared throttle paces their requests.
    func start() async {
        await withTaskGroup(of: Void.self) { group in
            for session in sessions { group.addTask { await session.start() } }
        }
    }

    func select(_ row: MergedListModel.Row) {
        guard let entry = row.entry else { return }
        selectedLogin = row.login
        lastUsed = row.login
        sessions[row.login].select(entry.bib)
    }

    func cancel(_ holds: [Hold], login: Int) async {
        await sessions[login].cancel(holds)
    }
}
