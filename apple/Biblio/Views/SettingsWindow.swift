import Observation
import SwiftUI

/// The signed-in windows that are open, and which one was frontmost most recently, so the
/// macOS Settings window knows whose account to show.
@Observable
final class SessionRegistry {
    static let shared = SessionRegistry()

    private(set) var sessions: [WindowSession] = []
    private(set) var activeID: ObjectIdentifier?

    var active: WindowSession? {
        sessions.first { ObjectIdentifier($0) == activeID } ?? sessions.last
    }

    func register(_ session: WindowSession) {
        guard !session.isGuest, !sessions.contains(where: { $0 === session }) else { return }
        sessions.append(session)
        activeID = ObjectIdentifier(session)
    }

    func unregister(_ session: WindowSession) {
        sessions.removeAll { $0 === session }
        if activeID == ObjectIdentifier(session) { activeID = sessions.last.map(ObjectIdentifier.init) }
    }

    func activate(_ session: WindowSession) {
        guard sessions.contains(where: { $0 === session }) else { return }
        activeID = ObjectIdentifier(session)
    }
}

#if os(macOS)
/// Settings (⌘,): account settings for the frontmost signed-in window, with a picker
/// when several accounts are open.
struct SettingsWindow: View {
    @State private var registry = SessionRegistry.shared
    @State private var chosen: ObjectIdentifier?

    private var session: WindowSession? {
        registry.sessions.first { ObjectIdentifier($0) == chosen } ?? registry.active
    }

    var body: some View {
        Group {
            if let session {
                VStack(spacing: 0) {
                    if registry.sessions.count > 1 {
                        Picker("Account", selection: Binding(get: { chosen ?? registry.activeID },
                                                             set: { chosen = $0 })) {
                            ForEach(registry.sessions, id: \.self.objectID) { s in
                                Text("\(s.patron?.name ?? s.username) — \(s.library.shortName ?? s.library.name)")
                                    .tag(Optional(s.objectID))
                            }
                        }
                        .padding([.horizontal, .top])
                    }
                    AccountView(session: session)
                        .id(session.objectID)
                        .tint(session.library.tint)
                        .overlay(alignment: .bottom) { BannerView(session: session) }
                }
            } else {
                ContentUnavailableView("No Account Open", systemImage: "person.crop.circle",
                                       description: Text("Open a library window and sign in to change account settings."))
            }
        }
        .frame(width: 520, height: 600)
        .onChange(of: registry.activeID) { chosen = nil }
    }
}
#endif

extension WindowSession {
    var objectID: ObjectIdentifier { ObjectIdentifier(self) }
}
