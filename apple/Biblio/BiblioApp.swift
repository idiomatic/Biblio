import SwiftUI

@main
struct BiblioApp: App {
    var body: some Scene {
        WindowGroup {
            WindowRoot()
        }
        .commands {
            SidebarCommands()
            InspectorCommands()
            RefreshCommands()
            #if os(macOS)
            AddAnotherCommands()
            AboutCommands()
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 760)
        #endif

        #if os(macOS)
        Settings {
            SettingsWindow()
        }
        #endif
    }
}

/// Each window starts at the library menu, then shows that library on a scope of its cards.
/// A window restored at launch reopens its scope.
struct WindowRoot: View {
    /// One card, or a guest.
    @State private var session: WindowSession?
    /// Instead of `session`, when the scope is several cards.
    @State private var combined: CombinedSession?
    @State private var windowID = UUID()
    @SceneStorage("lastLibrary") private var lastLibrary: String?
    /// The usernames this window has open, one per line ("" for a guest); nil while it shows the launcher.
    @SceneStorage("openUser") private var openUser: String?
    /// Set once this window has left its only login for the menus, so it doesn't reopen it.
    @State private var showingMenus = false
    /// The launcher then lists the libraries even when there is only one.
    @State private var listLibraries = false
    @State private var addingCard = false
    /// Set by a change of cards, which reopens a compact window on its sidebar.
    @State private var startOnSidebar = false
    /// The launcher waits for a restored window to reopen its cards.
    @State private var restored = false
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// The window's library as saved now, since its sessions keep the users it opened with.
    private var library: LibraryInfo? {
        (combined?.library ?? session?.library).map { LibraryStore.shared.library($0.subdomain) ?? $0 }
    }

    /// The cards in scope, in the library's order; none for a guest.
    private var scope: [String] {
        if let combined { return combined.sessions.map(\.username) }
        if let session, !session.isGuest { return [session.username] }
        return []
    }

    private var cardScope: CardScope? {
        guard let library, !scope.isEmpty else { return nil }
        let pool = ClientPool.shared
        return CardScope(library: library, current: scope,
                         isBusy: { pool.isInUse(subdomain: library.subdomain, username: $0, otherThan: windowID) },
                         set: { user, on in
                             setScope(on ? scope + [user] : scope.filter { $0 != user })
                         },
                         placeHold: { user, bib in
                             if let combined, let card = combined.sessions.firstIndex(where: { $0.username == user }) {
                                 Task { await combined.placeHolds([bib], target: .card(card)) }
                             } else if let session {
                                 Task { await session.placeHold(bib) }
                             }
                         },
                         add: { addingCard = true })
    }

    private var currentSection: AppSection? { combined?.section ?? session?.section }

    /// The sidebar item this library last had selected, unless it names a card that is gone.
    private var savedSection: AppSection? {
        guard let subdomain = lastLibrary, let section = LibraryStore.shared.section(for: subdomain) else { return nil }
        if case .account(let user) = section,
           !(LibraryStore.shared.library(subdomain)?.users.contains(user) ?? false) { return nil }
        return section
    }

    var body: some View {
        Group {
            if let combined {
                CombinedMainView(combined: combined, scope: cardScope, signOut: signOut, startOnSidebar: startOnSidebar)
                    #if os(iOS)
                    .id(ObjectIdentifier(combined))
                    #endif
            } else if let session {
                MainView(session: session, scope: cardScope, signOut: signOut, signIn: signIn, startOnSidebar: startOnSidebar)
                    #if os(iOS)
                    .id(ObjectIdentifier(session))
                    #endif
                    .tint(session.library.tint)
            } else if restored {
                LauncherView(preselectedLibrary: lastLibrary, listLibraries: listLibraries) { library, users in
                    open(library, users)
                }
            }
        }
        .task {
            restoreLogin()
            openSoleLogin()
            restored = true
            showRequestedCard()
        }
        .onOpenURL { url in
            if url.scheme == "biblio", url.host == "card" { LibraryCardRequest.request() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryCardRequested)) { _ in showRequestedCard() }
        .onChange(of: currentSection) { _, section in
            // Saved at once, since a window's own storage may lag a quit; leaving to the library
            // menu clears nothing.
            if let section, let library { LibraryStore.shared.noteSection(section, for: library.subdomain) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { ThrottleLog.sync() }
        }
        .sheet(isPresented: $addingCard) {
            if let library {
                AddUserView(library: library) { user in
                    let updated = LibraryStore.shared.library(library.subdomain) ?? library
                    setScope(updated.users.filter { scope.contains($0) || $0 == user })
                }
            }
        }
        // Closing the window (or quitting) frees its logins but keeps them in scene storage,
        // so a window restored at the next launch can reopen them.
        .onDisappear(perform: releaseLogin)
    }

    // MARK: Opening

    /// The launcher's choice: the cards to show, or none for a guest. The window opens on the
    /// library's sidebar, one level down, not in a list.
    private func open(_ library: LibraryInfo, _ users: [String], onSidebar: Bool = true, section: AppSection? = nil) {
        guard claim(users, in: library) else { return }
        startOnSidebar = onSidebar
        lastLibrary = library.subdomain
        show(library, users: users, previous: nil, section: section)
        showRequestedCard()
    }

    /// Reserves logins for this window; none is kept unless all are free.
    private func claim(_ users: [String], in library: LibraryInfo) -> Bool {
        var claimed: [String] = []
        for user in users {
            guard ClientPool.shared.claim(subdomain: library.subdomain, username: user, window: windowID) else {
                for c in claimed { ClientPool.shared.release(subdomain: library.subdomain, username: c, window: windowID) }
                return false
            }
            claimed.append(user)
        }
        return true
    }

    /// Shows the library on these cards (a guest if none), reusing the sessions already open and
    /// carrying the search, section, and selection over from `previous`.
    private func show(_ library: LibraryInfo, users: [String], previous: WindowSession?, section: AppSection?) {
        var existing: [String: WindowSession] = [:]
        for s in combined?.sessions ?? [] { existing[s.username] = s }
        if let session { existing[session.username] = session }
        let ordered = library.users.filter(users.contains)
        // Whatever this window had and no longer shows goes back to the other windows.
        for user in scope where !ordered.contains(user) {
            ClientPool.shared.release(subdomain: library.subdomain, username: user, window: windowID)
        }
        let sessions = (users.isEmpty ? [""] : ordered).map { user -> WindowSession in
            existing[user] ?? WindowSession(library: library, username: user)
        }
        for s in sessions { s.windowActions = windowActions }
        if let first = sessions.first, let previous, first !== previous { first.continueBrowsing(from: previous) }
        for old in existing.values where !sessions.contains(where: { $0 === old }) { SessionRegistry.shared.unregister(old) }
        openUser = users.isEmpty ? "" : ordered.joined(separator: "\n")
        LibraryStore.shared.noteScope(subdomain: library.subdomain, usernames: ordered)
        // The card last used stays the one the barcode shows, if it is still here.
        let last = LibraryStore.shared.lastLogin
        let lastHere = last.flatMap { $0.subdomain == library.subdomain && ordered.contains($0.username) ? $0.username : nil }
        if lastHere == nil, let first = ordered.first { LibraryStore.shared.noteLogin(subdomain: library.subdomain, username: first) }
        if sessions.count > 1 {
            let new = CombinedSession(library: library, sessions: sessions)
            new.windowActions = windowActions
            if let lastHere, let i = ordered.firstIndex(of: lastHere) { new.lastUsed = i }
            if let section { new.section = section }
            // A selected section opens its list on a compact screen; a scope change should
            // leave the sidebar, where it was made, showing.
            #if os(iOS)
            if startOnSidebar && sizeClass == .compact { new.section = nil }
            #endif
            combined = new
            session = nil
        } else {
            if let section { sessions[0].section = section }
            #if os(iOS)
            if startOnSidebar && sizeClass == .compact { sessions[0].section = nil }
            #endif
            session = sessions[0]
            combined = nil
        }
        for s in sessions { SessionRegistry.shared.register(s) }
    }

    /// Changes the window's cards in place.
    private func setScope(_ users: [String]) {
        guard let library, !users.isEmpty else { return }
        let old = scope
        let ordered = library.users.filter(users.contains)
        guard ordered != old else { return }
        let added = ordered.filter { !old.contains($0) }
        guard claim(added, in: library) else { return }
        let previous = session ?? combined?.primary
        startOnSidebar = true
        show(library, users: ordered, previous: previous, section: session?.section ?? combined?.section)
    }

    private var windowActions: WindowSession.WindowActions {
        .init(removeCard: removeCard,
              useDifferentLibrary: leaveForMenus,
              addCard: { addingCard = true })
    }

    private func leaveForMenus() { signOut() }

    /// Removes a card, with its saved password; the window stays on its other cards. The card
    /// may be out of this window, but not open in another.
    private func removeCard(_ user: String) {
        guard let library, library.users.contains(user),
              !ClientPool.shared.isInUse(subdomain: library.subdomain, username: user, otherThan: windowID) else { return }
        let subdomain = library.subdomain
        let remaining = scope.filter { $0 != user }
        // Leave the removed card's page.
        if case .account(user)? = session?.section { session?.section = nil }
        if case .account(user)? = combined?.section { combined?.section = nil }
        LibraryStore.shared.removeUser(user, from: subdomain)
        if scope.contains(user) {
            if remaining.isEmpty { leaveForMenus() } else { setScope(remaining) }
        }
        ClientPool.shared.discard(subdomain: subdomain, username: user)
    }

    /// With exactly one login saved, the window opens straight into it.
    private func openSoleLogin() {
        guard session == nil, combined == nil, !showingMenus, !LibraryCardRequest.pending,
              let sole = LibraryStore.shared.soleLogin else { return }
        open(sole.library, [sole.username], onSidebar: false, section: lastLibrary == sole.library.subdomain ? savedSection : nil)
    }

    /// Shows the requested library card in this window's signed-in session. A launcher window
    /// first opens the most recently used login, if no other window has it.
    private func showRequestedCard() {
        guard LibraryCardRequest.pending else { return }
        guard let active = session ?? combined?.cardSession else {
            openMostRecentLogin()
            return
        }
        guard !active.isGuest else { return }
        LibraryCardRequest.consume()
        active.showingLibraryCard = true
    }

    private func openMostRecentLogin() {
        guard let last = LibraryStore.shared.lastLogin, let library = LibraryStore.shared.library(last.subdomain),
              library.users.contains(last.username),
              !ClientPool.shared.isInUse(subdomain: last.subdomain, username: last.username) else { return }
        open(library, [last.username], onSidebar: false)   // shows the card once the session is open
    }

    /// Reopens the cards a restored window had, minus any removed or open in another window;
    /// the window then shows the launcher if none is left.
    private func restoreLogin() {
        guard session == nil, combined == nil, let saved = openUser, let subdomain = lastLibrary,
              let library = LibraryStore.shared.library(subdomain) else {
            if session == nil, combined == nil { openUser = nil }
            return
        }
        let users = saved.split(separator: "\n").map(String.init)
            .filter { library.users.contains($0) && !ClientPool.shared.isInUse(subdomain: subdomain, username: $0) }
        if saved.isEmpty {
            show(library, users: [], previous: nil, section: savedSection)
        } else if !users.isEmpty, claim(users, in: library) {
            show(library, users: users, previous: nil, section: savedSection)
        } else {
            openUser = nil
        }
    }

    /// Replaces a guest session with `user`'s, keeping the search and selection.
    private func signIn(_ user: String) {
        guard let guest = session, let library = LibraryStore.shared.library(guest.library.subdomain),
              claim([user], in: library) else { return }
        startOnSidebar = false
        show(library, users: [user], previous: guest, section: guest.section)
        showRequestedCard()
    }

    /// Back to the launcher.
    private func signOut() {
        showingMenus = true
        listLibraries = true
        openUser = nil
        releaseLogin()
    }

    private func releaseLogin() {
        for s in combined?.sessions ?? (session.map { [$0] } ?? []) {
            ClientPool.shared.release(subdomain: s.library.subdomain, username: s.username, window: windowID)
            SessionRegistry.shared.unregister(s)
        }
        combined = nil
        session = nil
    }
}
