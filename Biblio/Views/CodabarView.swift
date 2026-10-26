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
