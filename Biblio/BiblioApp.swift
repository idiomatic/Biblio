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
struct WindowRoot: View {
    @State private var session: WindowSession?
    @State private var windowID = UUID()
    @SceneStorage("lastLibrary") private var lastLibrary: String?

    var body: some View {
        Group {
            if let session {
                MainView(session: session, signOut: releaseLogin)
                    .tint(session.library.tint)
            } else {
                LauncherView(preselectedLibrary: lastLibrary) { library, user in
                    // The launcher disables logins open elsewhere; this guards against races.
                    guard ClientPool.shared.claim(subdomain: library.subdomain, username: user, window: windowID) else { return }
                    lastLibrary = library.subdomain
                    let new = WindowSession(library: library, username: user)
                    session = new
                    SessionRegistry.shared.register(new)
                }
            }
        }
        .onDisappear(perform: releaseLogin)
    }

    private func releaseLogin() {
        if let session {
            ClientPool.shared.release(subdomain: session.library.subdomain, username: session.username, window: windowID)
            SessionRegistry.shared.unregister(session)
        }
        session = nil
    }
}
