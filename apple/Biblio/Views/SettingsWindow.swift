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
/// Settings (⌘,): the card page of the frontmost window's current card, the same page its sidebar
/// shows. Cards are chosen in the window, not here.
struct SettingsWindow: View {
    @State private var registry = SessionRegistry.shared

    var body: some View {
        Group {
            if let session = registry.active {
                AccountView(session: session)
                    .id(session.objectID)
                    .tint(session.library.tint)
                    .overlay(alignment: .bottom) { BannerView(session: session) }
            } else {
                ContentUnavailableView("No Account Open", systemImage: "person.crop.circle",
                                       description: Text("Open a library window and sign in to change account settings."))
            }
        }
        .frame(width: 520, height: 600)
    }
}
#endif

extension WindowSession {
    var objectID: ObjectIdentifier { ObjectIdentifier(self) }
}
