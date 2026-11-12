import AppIntents
import Foundation

extension Notification.Name {
    static let libraryCardRequested = Notification.Name("libraryCardRequested")
}

/// Made when the Lock Screen control (or biblio://card) asks for the library card. The first
/// signed-in window to see it shows the card and consumes it; a launcher window keeps it
/// while the login it opens signs in, and when only guest windows remain, one of them opens
/// that login (in a new window where it can). Unconsumed requests lapse, so the card never shows
/// long after it was asked for.
@MainActor
enum LibraryCardRequest {
    private static var requestedAt: Date?
    private static var handedOff = false

    static var pending: Bool {
        guard let requestedAt else { return false }
        return Date.now.timeIntervalSince(requestedAt) < 10
    }

    static func request() {
        requestedAt = .now
        handedOff = false
        NotificationCenter.default.post(name: .libraryCardRequested, object: nil)
    }

    /// Whether the caller, a guest window, is the one to open the login: true once per request.
    static func handOff() -> Bool {
        guard pending, !handedOff else { return false }
        handedOff = true
        return true
    }

    static func consume() {
        requestedAt = nil
    }
}

/// What `ShowLibraryCardIntent` opens; an `OpenIntent` needs a target.
enum BiblioScreen: String, AppEnum {
    case libraryCard

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Screen"
    static let caseDisplayRepresentations: [BiblioScreen: DisplayRepresentation] = [.libraryCard: "Library Card"]
}

/// Opens Biblio and shows the library card barcode; the Lock Screen and Control Center
/// control runs it. As an `OpenIntent` in both targets, it runs in the app, not the extension.
struct ShowLibraryCardIntent: OpenIntent {
    static let title: LocalizedStringResource = "Show Library Card"

    @Parameter(title: "Screen", default: .libraryCard)
    var target: BiblioScreen

    @MainActor
    func perform() async throws -> some IntentResult {
        LibraryCardRequest.request()
        return .result()
    }
}
