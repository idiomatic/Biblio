import SwiftUI

/// The window's card's borrowed-before index, for rows (a combined window asks its cards instead).
private struct BorrowedIndexKey: EnvironmentKey {
    static let defaultValue: BorrowedIndex? = nil
}

extension EnvironmentValues {
    var borrowedIndex: BorrowedIndex? {
        get { self[BorrowedIndexKey.self] }
        set { self[BorrowedIndexKey.self] = newValue }
    }
}

/// How "borrowed before" reads, each phrase a whole localizable string.
enum BorrowedText {
    private static func formatted(_ date: String?, _ style: Date.FormatStyle) -> String? {
        date.flatMap(DateText.date).map { $0.formatted(style) }
    }

    /// What was borrowed: this item, or the work in another format, which reads "the audiobook",
    /// "on Blu-ray", "the book", or "as Kit".
    private enum What {
        case this, audiobook
        case on(String), the(String), `as`(String)

        init(_ m: BorrowedIndex.Match, library: LibraryInfo) {
            if m.sameFormat { self = .this; return }
            let name = library.formatName(m.format)
            switch m.format {
            case "AB", "BOOK_CD", "PLAYAWAY_AUDIOBOOK", "AUDIOBOOK": self = .audiobook
            case "DVD", "BLURAY", "UK", "DVD_PBLURAY", "VIDEO_ONLINE": self = .on(name)
            case "BK", "LPRINT", "EBOOK": self = .the(name.lowercased())
            default: self = .as(name)
            }
        }
    }

    /// For a row's tooltip: "Borrowed before · returned Mar 2024", or "Borrowed the audiobook".
    static func short(_ m: BorrowedIndex.Match, library: LibraryInfo) -> String {
        let when = formatted(m.lastReturned ?? m.lastCheckout, .dateTime.month(.abbreviated).year())
        let what: String
        var detail = when
        switch What(m, library: library) {
        case .this:
            what = String(localized: "Borrowed before")
            detail = when.map { m.lastReturned != nil ? String(localized: "returned \($0)") : String(localized: "borrowed \($0)") }
        case .audiobook: what = String(localized: "Borrowed the audiobook")
        case .on(let name): what = String(localized: "Borrowed on \(name)")
        case .the(let name): what = String(localized: "Borrowed the \(name)")
        case .as(let name): what = String(localized: "Borrowed as \(name)")
        }
        return [what, detail].compactMap { $0 }.joined(separator: " · ")
    }

    /// For item detail: "You borrowed this in March 2024 · 3 times", or "You borrowed the DVD in March 2024".
    static func sentence(_ m: BorrowedIndex.Match, library: LibraryInfo) -> String {
        let when = formatted(m.lastCheckout ?? m.lastReturned, .dateTime.month(.wide).year())
        var text: String
        switch (What(m, library: library), when) {
        case (.this, let when?): text = String(localized: "You borrowed this in \(when)")
        case (.this, nil): text = String(localized: "You borrowed this")
        case (.audiobook, let when?): text = String(localized: "You borrowed the audiobook in \(when)")
        case (.audiobook, nil): text = String(localized: "You borrowed the audiobook")
        case (.on(let name), let when?): text = String(localized: "You borrowed on \(name) in \(when)")
        case (.on(let name), nil): text = String(localized: "You borrowed on \(name)")
        case (.the(let name), let when?): text = String(localized: "You borrowed the \(name) in \(when)")
        case (.the(let name), nil): text = String(localized: "You borrowed the \(name)")
        case (.as(let name), let when?): text = String(localized: "You borrowed as \(name) in \(when)")
        case (.as(let name), nil): text = String(localized: "You borrowed as \(name)")
        }
        if m.count > 1 { text += " · " + inflected("^[\(m.count) time](inflect: true)") }
        return text
    }
}

/// A row's quiet "borrowed before" symbol, fainter for the same work in another format.
struct BorrowedMark: View {
    var match: BorrowedIndex.Match
    var library: LibraryInfo

    var body: some View {
        let text = BorrowedText.short(match, library: library)
        // As text, so it takes the line's height and baseline beside the availability text.
        Text(Image(systemName: "clock.arrow.circlepath"))
            .foregroundStyle(match.sameFormat ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .fixedSize()
            .help(text)
            .accessibilityLabel(text)
    }
}

/// Item detail's "You borrowed this…" line.
struct BorrowedLine: View {
    var match: BorrowedIndex.Match
    var library: LibraryInfo

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(match.sameFormat ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            Text(BorrowedText.sentence(match, library: library))
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// A card's borrowing history on its page: how many items it holds, a small progress bar while
/// it's read, and a button that reads it all again.
struct BorrowedHistoryRow: View {
    var index: BorrowedIndex
    var refresh: () -> Void

    private var count: Int { max(index.total, index.fetched) }

    private var progress: String {
        index.total > 0 ? "Updating · \(index.fetched.formatted()) of \(index.total.formatted())" : "Updating…"
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if count > 0 {
                    Text("^[\(count) Item](inflect: true) in your Borrowing History")
                } else if index.isSyncing {
                    Text("Reading your Borrowing History…")
                } else {
                    Text("No Items in your Borrowing History")
                }
            }
            .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if index.isSyncing {
                Group {
                    if index.total > 0 {
                        ProgressView(value: Double(min(index.fetched, index.total)), total: Double(index.total))
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                }
                .frame(width: 90)
                .controlSize(.small)
                .help(progress)
                .accessibilityLabel(progress)
                .transition(.opacity)
            }
            Button("Refresh Borrowing History", systemImage: "arrow.clockwise", action: refresh)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(index.isSyncing)
                .help("Read your borrowing history again")
        }
        .animation(.default, value: index.isSyncing)
    }
}

/// The sidebar's Borrowing History row, with a small gauge while the cards' histories are read (macOS).
struct HistorySidebarLabel: View {
    var indexes: [BorrowedIndex]

    var body: some View {
        HStack {
            Label(AppSection.history.title, systemImage: AppSection.history.systemImage)
            #if os(macOS)
            let syncing = indexes.filter(\.isSyncing)
            if !syncing.isEmpty {
                Spacer()
                let fetched = syncing.reduce(0) { $0 + $1.fetched }
                let total = syncing.reduce(0) { $0 + $1.total }
                Group {
                    if total > 0 {
                        ProgressView(value: Double(min(fetched, total)), total: Double(total))
                    } else {
                        ProgressView()
                    }
                }
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .help(total > 0 ? "Reading borrowing history · \(fetched.formatted()) of \(total.formatted())"
                                : "Reading borrowing history…")
            }
            #endif
        }
    }
}

/// The "Not Borrowed" filter's chip: shows only what the window's cards haven't borrowed in that format.
struct NotBorrowedChip: View {
    var isOn: Bool
    var toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Label("Not Borrowed", systemImage: isOn ? "checkmark" : "clock.arrow.circlepath")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isOn ? .accentColor : .secondary)
        .fixedSize()
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

extension CombinedSession {
    /// Each card's "borrowed before" for an item, the same format first.
    func borrowed(for bib: Bib) -> [(login: Int, match: BorrowedIndex.Match)] {
        sessions.indices.compactMap { login in sessions[login].borrowed.match(bib).map { (login, $0) } }
            .sorted { $0.match.sameFormat && !$1.match.sameFormat }
    }

    /// The included cards' indexes, for "Not Borrowed".
    var borrowedIndexes: [BorrowedIndex] { sessions.map(\.borrowed) }
}
