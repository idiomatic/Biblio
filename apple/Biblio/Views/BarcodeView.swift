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

/// Code 128, which scanners that skip Codabar still read.
nonisolated enum Code128 {
    /// Bar/space widths per symbol value, 6 elements (bar first), indexed by value; the last
    /// entry is the 7-element stop pattern.
    private static let patterns: [String] = [
        "212222", "222122", "222221", "121223", "121322", "131222", "122213", "122312", "132212", "221213",
        "221312", "231212", "112232", "122132", "122231", "113222", "123122", "123221", "223211", "221132",
        "221231", "213212", "223112", "312131", "311222", "321122", "321221", "312212", "322112", "322211",
        "212123", "212321", "232121", "111323", "131123", "131321", "112313", "132113", "132311", "211313",
        "231113", "231311", "112133", "112331", "132131", "113123", "113321", "133121", "313121", "211331",
        "231131", "213113", "213311", "213131", "311123", "311321", "331121", "312113", "312311", "332111",
        "314111", "221411", "431111", "111224", "111422", "121124", "121421", "141122", "141221", "112214",
        "112412", "122114", "122411", "142112", "142211", "241211", "221114", "413111", "241112", "134111",
        "111242", "121142", "121241", "114212", "124112", "124211", "411212", "421112", "421211", "212141",
        "214121", "412121", "111143", "111341", "131141", "114113", "114311", "411113", "411311", "113141",
        "114131", "311141", "411131", "211412", "211214", "211232", "2331112",
    ]
    private static let startB = 104, startC = 105, codeC = 99, stop = 106

    /// Element widths in narrow units for `value`, bar first. All-digit values use subset C
    /// (digit pairs, with an odd leading digit in subset B); anything else uses subset B. Nil if
    /// `value` is empty or has characters subset B can't encode.
    static func elements(for value: String) -> [Double]? {
        let codes = value.unicodeScalars.map { Int($0.value) }
        guard !codes.isEmpty, codes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return nil }
        var symbols: [Int]
        if codes.count >= 2, codes.allSatisfy({ $0 >= 48 && $0 <= 57 }) {
            let digits = codes.map { $0 - 48 }
            let odd = digits.count % 2 == 1
            symbols = odd ? [startB, digits[0] + 16, codeC] : [startC]
            for k in stride(from: odd ? 1 : 0, to: digits.count, by: 2) { symbols.append(digits[k] * 10 + digits[k + 1]) }
        } else {
            symbols = [startB] + codes.map { $0 - 32 }
        }
        let checksum = symbols.enumerated().reduce(0) { $0 + ($1.offset == 0 ? $1.element : $1.element * $1.offset) } % 103
        symbols += [checksum, stop]
        return symbols.flatMap { patterns[$0].map { Double($0.wholeNumberValue!) } }
    }
}

enum BarcodeSymbology: String, CaseIterable, Identifiable {
    case codabar, code128

    var id: String { rawValue }
    var name: String { self == .codabar ? "Codabar" : "Code 128" }

    func elements(for value: String) -> [Double]? {
        switch self {
        case .codabar: Codabar.elements(for: value)
        case .code128: Code128.elements(for: value)
        }
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
