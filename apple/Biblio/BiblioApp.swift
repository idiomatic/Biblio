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

/// Each window starts at the library menu, then the user menu, then the catalog.
/// A window restored at launch reopens the login it had open.
struct WindowRoot: View {
    @State private var session: WindowSession?
    @State private var windowID = UUID()
    @SceneStorage("lastLibrary") private var lastLibrary: String?
    /// The username this window has open ("" for a guest); nil while it shows the launcher.
    @SceneStorage("openUser") private var openUser: String?

    var body: some View {
        Group {
            if let session {
                MainView(session: session, signOut: signOut, signIn: signIn)
                    #if os(iOS)
                    .id(ObjectIdentifier(session))
                    #endif
                    .tint(session.library.tint)
            } else {
                LauncherView(preselectedLibrary: lastLibrary) { library, user in
                    open(library, user)
                }
            }
        }
        .task {
            restoreLogin()
            showRequestedCard()
        }
        .onOpenURL { url in
            if url.scheme == "biblio", url.host == "card" { LibraryCardRequest.request() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryCardRequested)) { _ in showRequestedCard() }
        // Closing the window (or quitting) frees its login but keeps it in scene storage,
        // so a window restored at the next launch can reopen it.
        .onDisappear(perform: releaseLogin)
    }

    private func open(_ library: LibraryInfo, _ user: String) {
        // The launcher disables logins open elsewhere; this guards against races.
        guard ClientPool.shared.claim(subdomain: library.subdomain, username: user, window: windowID) else { return }
        lastLibrary = library.subdomain
        openUser = user
        LibraryStore.shared.noteLogin(subdomain: library.subdomain, username: user)
        let new = WindowSession(library: library, username: user)
        session = new
        SessionRegistry.shared.register(new)
        showRequestedCard()
    }

    /// Shows the requested library card in this window's signed-in session. A launcher window
    /// first opens the most recently used login, if no other window has it.
    private func showRequestedCard() {
        guard LibraryCardRequest.pending else { return }
        guard let session else {
            openMostRecentLogin()
            return
        }
        guard !session.isGuest else { return }
        LibraryCardRequest.consume()
        session.showingLibraryCard = true
    }

    private func openMostRecentLogin() {
        guard let last = LibraryStore.shared.lastLogin, let library = LibraryStore.shared.library(last.subdomain),
              library.users.contains(last.username),
              !ClientPool.shared.isInUse(subdomain: last.subdomain, username: last.username) else { return }
        open(library, last.username)   // shows the card once the session is open
    }

    /// Reopens the login a restored window had, unless the library or user was removed
    /// or another window already has it; the window then shows the launcher.
    private func restoreLogin() {
        guard session == nil, let user = openUser else { return }
        if let subdomain = lastLibrary, let library = LibraryStore.shared.library(subdomain),
           user.isEmpty || library.users.contains(user),
           !ClientPool.shared.isInUse(subdomain: subdomain, username: user) {
            open(library, user)
        } else {
            openUser = nil
        }
    }

    /// Replaces a guest session with `user`'s, keeping the search and selection.
    private func signIn(_ user: String) {
        guard let guest = session,
              ClientPool.shared.claim(subdomain: guest.library.subdomain, username: user, window: windowID) else { return }
        let library = LibraryStore.shared.library(guest.library.subdomain) ?? guest.library
        let new = WindowSession(library: library, username: user)
        new.continueBrowsing(from: guest)
        SessionRegistry.shared.unregister(guest)
        openUser = user
        LibraryStore.shared.noteLogin(subdomain: library.subdomain, username: user)
        session = new
        SessionRegistry.shared.register(new)
        showRequestedCard()
    }

    /// Back to the launcher.
    private func signOut() {
        openUser = nil
        releaseLogin()
    }

    private func releaseLogin() {
        if let session {
            ClientPool.shared.release(subdomain: session.library.subdomain, username: session.username, window: windowID)
            SessionRegistry.shared.unregister(session)
        }
        session = nil
    }
}
