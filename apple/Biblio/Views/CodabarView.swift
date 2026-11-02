import SwiftUI

/// Codabar, the symbology most North American library cards use.
nonisolated enum Codabar {
    /// Bar/space widths per character, 7 elements (bar, space, bar, space, bar, space, bar);
    /// 1 = wide, 0 = narrow.
    private static let patterns: [Character: String] = [
        "0": "0000011", "1": "0000110", "2": "0001001", "3": "1100000", "4": "0010010",
        "5": "1000010", "6": "0100001", "7": "0100100", "8": "0110000", "9": "1001000",
        "-": "0001100", "$": "0011000", ":": "1000101", "/": "1010001", ".": "1010100",
        "+": "0010101", "A": "0011010", "B": "0101001", "C": "0001011", "D": "0001110",
    ]

    /// Element widths in narrow units for `value` wrapped in start/stop characters,
    /// with a narrow gap between characters. Nil if `value` has characters Codabar can't encode.
    static func elements(for value: String, start: Character = "A", stop: Character = "A",
                         wideRatio: Double = 2.5) -> [Double]? {
        let body = value.uppercased()
        let hasOwnGuards = body.count >= 2 && "ABCD".contains(body.first!) && "ABCD".contains(body.last!)
        let text = hasOwnGuards ? body : "\(start)\(body)\(stop)"
        var out: [Double] = []
        for (i, ch) in text.enumerated() {
            guard let p = patterns[ch] else { return nil }
            if i > 0 { out.append(1) }   // inter-character gap (a space)
            out += p.map { $0 == "1" ? wideRatio : 1 }
        }
        return out
    }
}

/// A scannable library-card barcode: black bars on white (also in dark mode), with
/// quiet zones and the number printed underneath.
struct CodabarView: View {
    var value: String

    var body: some View {
        if let elements = Codabar.elements(for: value) {
            VStack(spacing: 6) {
                Canvas { context, size in
                    let quiet = 10.0   // quiet zone, in narrow units, on each side
                    let unit = size.width / (elements.reduce(0, +) + 2 * quiet)
                    var x = quiet * unit
                    for (i, w) in elements.enumerated() {
                        // Elements alternate bar, space, … within a character, and the gap
                        // after each 7-element character is a space, so even indices are bars.
                        if i % 2 == 0 {
                            context.fill(Path(CGRect(x: x, y: 0, width: w * unit, height: size.height)), with: .color(.black))
                        }
                        x += w * unit
                    }
                }
                .frame(height: 64)
                Text(value)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.black)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .environment(\.colorScheme, .light)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Library card barcode")
            .accessibilityValue(value)
        } else {
            LabeledContent("Card", value: value)
        }
    }
}

/// A toolbar button that shows the library card's barcode, for scanning at the library:
/// a popover on macOS and iPad, a sheet on iPhone.
struct LibraryCardButton: View {
    @Bindable var session: WindowSession

    var body: some View {
        Button {
            session.showingLibraryCard = true
        } label: {
            Label("Library Card", systemImage: "barcode")
        }
        .help("Show your library card")
        .disabled(session.patron?.barcode == nil)
        .popover(isPresented: $session.showingLibraryCard) {
            if let card = session.card {
                LibraryCardPager(current: card)
                    .frame(idealWidth: 380)
                    .presentationDetents([.height(300)])
            } else {
                ProgressView().padding()
            }
        }
    }
}

/// The library cards of every login, the one in use first. On iOS and iPadOS, swipe left or
/// right to rotate between them; macOS shows only the current card.
struct LibraryCardPager: View {
    var current: CardInfo
    @State private var selection: String

    init(current: CardInfo) {
        self.current = current
        _selection = State(initialValue: current.id)
    }

    /// A page per login, the current one first; logins without a card yet get a placeholder.
    private struct Slot: Identifiable {
        var id: String
        var username: String
        var library: LibraryInfo
        var card: CardInfo?
        var unavailable: Bool
    }

    private var slots: [Slot] {
        #if os(iOS)
        let store = LibraryStore.shared
        let all = store.libraries.flatMap { library in
            library.users.map { user in
                let id = CardInfo.id(subdomain: library.subdomain, username: user)
                return Slot(id: id, username: user, library: library, card: id == current.id ? current : store.cards[id],
                            unavailable: store.unavailableCards.contains(id))
            }
        }
        return all.filter { $0.id == current.id } + all.filter { $0.id != current.id }
        #else
        []
        #endif
    }

    var body: some View {
        #if os(iOS)
        let slots = slots
        TabView(selection: $selection) {
            ForEach(slots) { slot in
                Group {
                    if let card = slot.card {
                        page(card)
                    } else {
                        placeholder(slot)
                    }
                }
                .tag(slot.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: slots.count > 1 ? .always : .never))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .task { await LibraryStore.shared.fetchMissingCards() }
        #else
        page(current)
        #endif
    }

    private func placeholder(_ slot: Slot) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(slot.username)
                    .font(.headline)
                Text(slot.library.shortName ?? slot.library.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Group {
                if slot.unavailable {
                    Text("This card couldn’t be loaded. Sign in as \(slot.username) to show it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    ProgressView()
                }
            }
            .frame(height: 100)
        }
        .padding()
        .padding(.bottom, 24)
    }

    private func page(_ card: CardInfo) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(card.name)
                    .font(.headline)
                Text(card.library)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            CodabarView(value: card.barcode)
            Text("Show this at the library’s self-checkout or desk.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .padding(.bottom, 24)
    }
}
