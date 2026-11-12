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
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if let elements = symbology.elements(for: value) {
            VStack(spacing: 6) {
                Canvas { context, size in
                    // Whole device pixels per element, so no bar edge blurs across a pixel.
                    let scale = displayScale
                    let quiet = 10.0   // quiet zone, in narrow units, on each side
                    let unit = max(1, (size.width * scale / (elements.reduce(0, +) + 2 * quiet)).rounded(.down))
                    let pixels = elements.map { max(1, ($0 * unit).rounded()) }
                    var x = ((size.width * scale - pixels.reduce(0, +)) / 2).rounded(.down)
                    for (i, w) in pixels.enumerated() {
                        // Elements alternate bar, space, …, and the first is a bar.
                        if i % 2 == 0 {
                            context.fill(Path(CGRect(x: x / scale, y: 0, width: w / scale, height: size.height)), with: .color(.black))
                        }
                        x += w
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

#if os(iOS)
/// A toolbar button that shows the library card's barcode, for scanning at the library:
/// a popover on iPad, a sheet on iPhone.
struct LibraryCardButton: View {
    @Bindable var session: WindowSession
    @Environment(\.isShort) private var isShort
    /// The pager's height, measured from its pages, which sizes the popover and the sheet.
    @State private var height: CGFloat = 300

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
                LibraryCardPager(current: card, height: $height)
                    .frame(idealWidth: 380)
                    .presentationDetents(isShort ? [.large] : [.height(height)])
            } else {
                ProgressView().padding()
            }
        }
    }
}

/// The library cards of the current card's library, its login first; swipe left or right to
/// rotate between them.
struct LibraryCardPager: View {
    var current: CardInfo
    /// The tallest page's height: a paged TabView has none of its own.
    @Binding var height: CGFloat
    @State private var heights: [String: CGFloat] = [:]
    @State private var selection: String

    init(current: CardInfo, height: Binding<CGFloat>) {
        self.current = current
        _height = height
        _selection = State(initialValue: current.id)
    }

    /// The remembered card of every login at the library, the current one first.
    private var cards: [CardInfo] {
        let store = LibraryStore.shared
        let others = (store.library(current.subdomain)?.users ?? [])
            .compactMap { store.cards[CardInfo.id(subdomain: current.subdomain, username: $0)] }
            .filter { $0.id != current.id }
        return [current] + others
    }

    var body: some View {
        let cards = cards
        TabView(selection: $selection) {
            ForEach(cards) { card in
                page(card, dots: cards.count > 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { new in
                        heights[card.id] = new
                        let tallest = heights.values.max() ?? new
                        if abs(tallest - height) > 0.5 { height = tallest }
                    }
                    .tag(card.id)
            }
        }
        .frame(height: height)
        .tabViewStyle(.page(indexDisplayMode: cards.count > 1 ? .always : .never))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
    }

    /// One card; `dots` leaves room below for the page indicator.
    private func page(_ card: CardInfo, dots: Bool) -> some View {
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
        .padding(.bottom, dots ? 24 : 0)
    }
}
#endif
