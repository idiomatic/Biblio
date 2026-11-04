import BiblioCore
import SwiftUI

enum BarcodeSymbology: String, CaseIterable, Identifiable {
    case codabar, code128

    var id: String { rawValue }
    var name: String { self == .codabar ? "Codabar" : "Code 128" }

    /// Element widths in narrow units, bar first, from the core; nil if `value` can't be encoded.
    func elements(for value: String) -> [Double]? {
        var count = 0
        guard let widths = biblio_barcode(value, self == .codabar ? BIBLIO_CODABAR : BIBLIO_CODE128, &count) else { return nil }
        defer { biblio_free(widths) }
        return Array(UnsafeBufferPointer(start: widths, count: count))
    }
}

/// A scannable library-card barcode: black bars on white (also in dark mode), with
/// quiet zones and the number printed underneath, and a choice of symbology that sticks
/// for every card.
struct BarcodeView: View {
    var value: String
    @AppStorage("cardSymbology") private var symbology = BarcodeSymbology.codabar

    var body: some View {
        VStack(spacing: 10) {
            bars
            Picker("Barcode type", selection: $symbology) {
                ForEach(BarcodeSymbology.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    @ViewBuilder private var bars: some View {
        if let elements = symbology.elements(for: value) {
            VStack(spacing: 6) {
                Canvas { context, size in
                    let quiet = 10.0   // quiet zone, in narrow units, on each side
                    let unit = size.width / (elements.reduce(0, +) + 2 * quiet)
                    var x = quiet * unit
                    for (i, w) in elements.enumerated() {
                        // Elements alternate bar, space, …, and the first is a bar.
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
            .accessibilityLabel("Library card barcode, \(symbology.name)")
            .accessibilityValue(value)
        } else {
            LabeledContent("Card", value: value)
            Text("\(symbology.name) can't encode this card number.")
                .font(.footnote)
                .foregroundStyle(.secondary)
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
                    .presentationDetents([.height(350)])
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

    /// The remembered card of every login, the current one first.
    private var cards: [CardInfo] {
        #if os(iOS)
        let store = LibraryStore.shared
        let others = store.libraries.flatMap { library in
            library.users.compactMap { store.cards[CardInfo.id(subdomain: library.subdomain, username: $0)] }
        }.filter { $0.id != current.id }
        return [current] + others
        #else
        [current]
        #endif
    }

    var body: some View {
        #if os(iOS)
        let cards = cards
        TabView(selection: $selection) {
            ForEach(cards) { card in
                page(card).tag(card.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: cards.count > 1 ? .always : .never))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        #else
        page(current)
        #endif
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
            BarcodeView(value: card.barcode)
            Text("Show this at the library’s self-checkout or desk.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .padding(.bottom, 24)
    }
}
