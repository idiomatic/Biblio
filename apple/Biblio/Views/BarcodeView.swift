import BiblioCore
import SwiftUI

nonisolated enum BarcodeSymbology: String, CaseIterable, Identifiable, Codable, Sendable {
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

extension EnvironmentValues {
    /// Whether the window is short, as on an iPhone in landscape.
    var isShort: Bool {
        #if os(iOS)
        verticalSizeClass == .compact
        #else
        false
        #endif
    }
}

/// A scannable library-card barcode: black bars on white (also in dark mode), with
/// quiet zones and the number printed underneath. It grows in short windows.
struct BarcodeView: View {
    var value: String
    var symbology: BarcodeSymbology
    @Environment(\.isShort) private var isShort

    var body: some View {
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
                .frame(height: isShort ? 120 : 64)
                Text(value)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.black)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: isShort ? 720 : 420)
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

/// A library card barcode with a picker for the library's barcode type, which sticks for
/// every card of that library.
struct BarcodeWithPicker: View {
    var value: String
    var subdomain: String

    var body: some View {
        let store = LibraryStore.shared
        let symbology = Binding(get: { store.symbology(for: subdomain) },
                                set: { store.setSymbology($0, for: subdomain) })
        VStack(spacing: 10) {
            BarcodeView(value: value, symbology: symbology.wrappedValue)
            Picker("Barcode type", selection: symbology) {
                ForEach(BarcodeSymbology.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

/// A toolbar button that shows the library card's barcode, for scanning at the library:
/// a popover on macOS and iPad, a sheet on iPhone.
struct LibraryCardButton: View {
    @Bindable var session: WindowSession
    @Environment(\.isShort) private var isShort

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
                    .presentationDetents(isShort ? [.large] : [.height(300)])
            } else {
                ProgressView().padding()
            }
        }
    }
}

/// The library cards of the current card's library, its login first. On iOS and iPadOS, swipe
/// left or right to rotate between them; macOS shows only the current card.
struct LibraryCardPager: View {
    var current: CardInfo
    @State private var selection: String

    init(current: CardInfo) {
        self.current = current
        _selection = State(initialValue: current.id)
    }

    /// The remembered card of every login at the library, the current one first.
    private var cards: [CardInfo] {
        #if os(iOS)
        let store = LibraryStore.shared
        let others = (store.library(current.subdomain)?.users ?? [])
            .compactMap { store.cards[CardInfo.id(subdomain: current.subdomain, username: $0)] }
            .filter { $0.id != current.id }
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
            BarcodeView(value: card.barcode, symbology: LibraryStore.shared.symbology(for: card.subdomain))
            Text("Show this at the library’s self-checkout or desk.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .padding(.bottom, 24)
    }
}
