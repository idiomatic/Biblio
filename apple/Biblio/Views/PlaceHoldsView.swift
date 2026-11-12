import SwiftUI

/// "Place Holds" in a combined window: the titles chosen to hold, in a section for each card.
/// Titles start on their default card; drag one to another card's section, or use its context
/// menu's "Move to…", then place them all. A card that already holds or has a title out refuses it.
/// (Self-contained: the hooks are in `MultiSelectionView` and the compact selection bar.)
struct PlaceHoldsView: View {
    var combined: CombinedSession
    var bibs: [Bib]
    /// Called after the holds are placed, e.g. to close the sheet that shows this.
    var onPlaced: () -> Void = {}

    /// Title id → the card index it goes on.
    @State private var assignment: [String: Int]
    @State private var working = false
    /// Why the last move was refused; shown here because a sheet covers the window's banner.
    @State private var notice: String?

    init(combined: CombinedSession, bibs: [Bib], onPlaced: @escaping () -> Void = {}) {
        self.combined = combined
        self.bibs = bibs
        self.onPlaced = onPlaced
        var start: [String: Int] = [:]
        for bib in bibs { start[bib.id] = combined.cardForHold(bib) ?? 0 }
        _assignment = State(initialValue: start)
    }

    private var placeable: [Bib] { bibs.filter { assignment[$0.id] != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("^[\(bibs.count) Item](inflect: true) to Hold")
                    .font(.title3.weight(.semibold))
                Spacer()
                if combined.sessions.count > 1 {
                    Button("Split Evenly", systemImage: "arrow.left.arrow.right", action: splitEvenly)
                        .buttonStyle(.borderless)
                        .help("Share the titles out among the cards, the one with the fewest holds first")
                }
            }
            if let notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            ForEach(combined.sessions.indices, id: \.self) { card in section(card) }
            Button {
                working = true
                Task {
                    await combined.placeHolds(placeable, target: .assigned(assignment))
                    working = false
                    onPlaced()
                }
            } label: {
                HStack {
                    if working { ProgressView().controlSize(.small) }
                    Text("Place ^[\(placeable.count) Hold](inflect: true)")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(working || placeable.isEmpty)
        }
    }

    private func section(_ card: Int) -> some View {
        let mine = bibs.filter { assignment[$0.id] == card }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                CardChip(style: combined.style(card), size: 18)
                Text("For \(combined.name(card)) · \(mine.count)").font(.subheadline.weight(.semibold))
            }
            if mine.isEmpty {
                Text("Drop titles here")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .dropDestination(for: String.self) { ids, _ in move(ids, to: card) }
            }
            ForEach(mine, id: \.id) { bib in
                row(bib, in: card)
                    .dropDestination(for: String.self) { ids, _ in move(ids, to: card) }
            }
        }
        .padding(8)
        .background(combined.style(card).color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ bib: Bib, in card: Int) -> some View {
        HStack(spacing: 10) {
            CoverImage(url: bib.jacketSmall, format: bib.format)
                .frame(width: 30, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(bib.fullTitle).font(.callout).lineLimit(2)
                Text(combined.library.formatName(bib.format)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .draggable(bib.id)
        .contextMenu {
            ForEach(combined.sessions.indices.filter { $0 != card }, id: \.self) { other in
                Button("Move to \(combined.name(other))") { _ = move([bib.id], to: other) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Drag to another card, or use the actions menu to move it")
    }

    /// Moves titles to a card, unless it already has them.
    private func move(_ ids: [String], to card: Int) -> Bool {
        var moved = false
        for id in ids {
            guard let bib = bibs.first(where: { $0.id == id }), assignment[id] != card else { continue }
            guard combined.cardsAbleToHold(bib).contains(card) else {
                notice = "\(combined.name(card)) already has “\(bib.title)”."
                continue
            }
            assignment[id] = card
            notice = nil
            moved = true
        }
        return moved
    }

    /// Shares the titles out, the card with the fewest holds (counting these) first.
    private func splitEvenly() {
        var counts = combined.sessions.map { $0.holdsList.total }
        var next: [String: Int] = [:]
        for bib in bibs {
            let able = combined.cardsAbleToHold(bib)
            guard let card = able.min(by: { counts[$0] != counts[$1] ? counts[$0] < counts[$1] : $0 < $1 }) else { continue }
            next[bib.id] = card
            counts[card] += 1
        }
        withAnimation { assignment = next }
    }
}
