import SwiftUI

/// Inspector pane for one item. Availability by location loads in the background.
/// The cover and the title block can be dragged onto Holds or onto any window's search field.
struct ItemDetailView: View {
    @Bindable var session: WindowSession
    var bib: Bib
    /// In a combined window, every card's relationship to the item shows, and holds pick a card.
    var cards: CombinedSession?

    @State private var copies: [CopyAvailability]?
    @State private var copiesError: String?
    @State private var fields: [DetailField] = []
    @State private var pickup: String?
    @State private var placing = false
    @State private var canceling = false
    @State private var confirmCancel = false
    @State private var showAllCopies = false
    @State private var paneWidth: CGFloat = 500

    private var transfer: BibTransfer { BibTransfer(subdomain: session.library.subdomain, bib: bib) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if cards == nil, let status = session.accountStatus(for: bib.id) {
                    AccountStatusTag(status: status, hold: session.hold(for: bib.id))
                }
                if let cards {
                    CardsHoldSection(combined: cards, bib: bib)
                    ForEach(cards.borrowed(for: bib), id: \.login) { mark in
                        HStack(spacing: 6) {
                            CardChip(style: cards.style(mark.login), size: 16)
                            BorrowedLine(match: mark.match, library: session.library)
                        }
                    }
                } else {
                    holdSection
                    if let borrowed = session.borrowed.match(bib) {
                        BorrowedLine(match: borrowed, library: session.library)
                    }
                }
                if let summary = bib.summary {
                    Text(summary)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                availabilitySection
                detailsSection
            }
            .padding()
            // A comfortable reading width on a landscape phone or a wide sheet.
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paneWidth = $0 }
        .navigationTitle(bib.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // The account may still be loading when the item opens, e.g. right after a guest signs in.
        .onChange(of: session.patron?.preferredPickup, initial: true) { _, preferred in
            if pickup == nil { pickup = preferred }
        }
        // A list refresh bumps the revision, so the item's availability and details load again.
        .task(id: [bib.id, String(session.detailsRevision)]) {
            pickup = pickup ?? session.patron?.preferredPickup
            async let avail: Void = loadAvailability()
            async let details: Void = loadFields()
            _ = await (avail, details)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            CoverImage(url: bib.jacketLarge, format: bib.format)
                .frame(width: 110, height: 160)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                // Undocumented convenience: drop on Holds to place a hold, or on any search field to search.
                .draggable(transfer) { dragPreview }
            VStack(alignment: .leading, spacing: 6) {
                Text(bib.title)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                if let subtitle = bib.subtitle {
                    // Regular weight, as in the list: a subtitle, not a second title.
                    Text(subtitle).font(.headline.weight(.regular)).foregroundStyle(.secondary)
                }
                ForEach(bib.authors.prefix(3), id: \.self) { author in
                    Button(author) { session.runSearch("contributor:(\(author))", searchType: "bl") }
                        .buttonStyle(.borderless)
                        .help("Search for this author")
                }
                // Format, year, and edition, in the list row's style but a line each, using the room
                // beside the cover. The brief record keeps only the first edition statement; the full
                // record has them all.
                let edition = fields.first(where: { $0.label == "Edition" })?.values.joined(separator: " · ") ?? bib.edition
                ForEach([session.library.formatName(bib.format), bib.displayDate, edition]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }, id: \.self) { line in
                    Text(line)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var dragPreview: some View {
        HStack {
            Image(systemName: "book.closed.fill")
            Text(bib.title).lineLimit(1)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var holdSection: some View {
        if session.isGuest {
            VStack(alignment: .leading, spacing: 4) {
                AvailabilityBadge(bib: bib)
                if bib.holdable {
                    Button("Sign In to Place a Hold…", systemImage: "person.crop.circle") {
                        session.requestSignIn()
                    }
                    .buttonStyle(.bordered)
                }
            }
        } else if let hold = session.hold(for: bib.id) {
            VStack(alignment: .leading, spacing: 8) {
                AvailabilityBadge(bib: bib)
                if !hold.canCancel {
                    Label(hold.status == "READY_FOR_PICKUP"
                          ? "This library doesn’t allow canceling a hold that’s ready for pickup."
                          : "This library doesn’t allow canceling this hold online.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(role: .destructive) {
                        confirmCancel = true
                    } label: {
                        if canceling { ProgressView().controlSize(.small) }
                        else { Label("Cancel Hold", systemImage: "xmark.circle") }
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(canceling)
                    .confirmationDialog("Cancel your hold on “\(bib.title)”?", isPresented: $confirmCancel) {
                        Button("Cancel Hold", role: .destructive) {
                            canceling = true
                            Task {
                                await session.cancel([hold])
                                canceling = false
                            }
                        }
                        Button("Keep Hold", role: .cancel) {}
                    } message: {
                        if hold.status == "READY_FOR_PICKUP" {
                            Text("This item is waiting for you. Canceling releases it to the next person.")
                        } else if let p = hold.position {
                            Text("You’ll lose your place (#\(p)) in line.")
                        }
                    }
                }
            }
        } else if session.accountStatus(for: bib.id) != nil {
            // Checked out: the tag above says so; no hold to place.
            AvailabilityBadge(bib: bib)
        } else if bib.holdable {
            VStack(alignment: .leading, spacing: 8) {
                AvailabilityBadge(bib: bib)
                let picker = Group {
                    if !session.locations.isEmpty {
                        Picker("Pick up at", selection: $pickup) {
                            ForEach(session.locations) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .labelsHidden()
                        .lineLimit(1)
                        .fixedSize()
                    }
                }
                let hold = Button {
                    placing = true
                    Task {
                        await session.placeHold(bib, pickup: pickup)
                        placing = false
                    }
                } label: {
                    if placing { ProgressView().controlSize(.small) }
                    else { Label("Hold", systemImage: "tray.and.arrow.down").fixedSize() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(placing)
                // Side by side when they fit, else one above the other (a long branch name on a phone).
                ViewThatFits(in: .horizontal) {
                    HStack { picker; hold }
                    VStack(alignment: .leading, spacing: 8) { picker; hold }
                }
            }
        } else {
            AvailabilityBadge(bib: bib)
        }
    }

    /// A copy's status, with its due date when it's checked out.
    private func copyStatus(_ copy: CopyAvailability) -> Text {
        var text = Text(copy.status).foregroundStyle(StatusColors.copy(copy))
        if let due = copy.dueDate {
            text = text + Text(" · due \(DateText.format(due))").foregroundStyle(.secondary)
        }
        return text
    }

    /// Whether the pane is too narrow for side-by-side columns: a phone, or a narrow pane on an
    /// iPad or Mac, whatever the size class says.
    private var compact: Bool { paneWidth < 460 }

    private var availabilitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Availability by Location").font(.headline)
            if let copies {
                if copies.isEmpty {
                    Text(bib.status == "ON_ORDER" ? "On order — no copies on the shelf yet." : "No copies listed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    let shown = showAllCopies ? copies : Array(copies.prefix(12))
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach(shown) { copy in
                            GridRow {
                                Image(systemName: copy.kind.systemImage)
                                    .foregroundStyle(StatusColors.copy(copy))
                                    .imageScale(copy.kind == .available ? .medium : .small)
                                    .frame(minWidth: 18)
                                if compact {
                                    // Status under the branch: three columns would clip on a phone.
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(copy.branch).lineLimit(2)
                                        copyStatus(copy).font(.subheadline)
                                    }
                                } else {
                                    Text(copy.branch)
                                        .lineLimit(2)
                                    copyStatus(copy)
                                }
                            }
                            .font(.callout)
                            .help([copy.collection, copy.callNumber].compactMap { $0 }.joined(separator: "\n"))
                            .accessibilityElement(children: .combine)
                            .accessibilityHint([copy.collection, copy.callNumber].compactMap { $0 }.joined(separator: ", "))
                        }
                    }
                    if copies.count > shown.count || showAllCopies && copies.count > 12 {
                        Button(showAllCopies ? "Show Fewer" : "Show All \(copies.count) Copies") {
                            withAnimation { showAllCopies.toggle() }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } else if let copiesError {
                Label(copiesError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var detailsSection: some View {
        if !fields.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Details").font(.headline)
                if compact {
                    // Label over value: a phone's width is better spent on the values.
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(fields) { field in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(field.label).font(.caption).foregroundStyle(.secondary)
                                Text(field.values.joined(separator: "\n")).textSelection(.enabled)
                            }
                            .font(.callout)
                        }
                    }
                } else {
                    Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach(fields) { field in
                            GridRow {
                                Text(field.label)
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                Text(field.values.joined(separator: "\n"))
                                    .textSelection(.enabled)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
    }

    private func loadAvailability() async {
        do {
            let result = try await session.client.availability(bib.id)
            withAnimation { copies = result }
        } catch {
            copiesError = error.localizedDescription
        }
    }

    private func loadFields() async {
        if let result = try? await session.client.detailFields(bib.id) {
            withAnimation { fields = result }
        }
    }
}
