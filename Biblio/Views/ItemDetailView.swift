import SwiftUI

/// Inspector pane for one item. Availability by location loads in the background.
/// The cover and the title block can be dragged onto Holds or onto any window's search field.
struct ItemDetailView: View {
    @Bindable var session: WindowSession
    var bib: Bib

    @State private var copies: [CopyAvailability]?
    @State private var copiesError: String?
    @State private var fields: [DetailField] = []
    @State private var pickup: String?
    @State private var placing = false
    @State private var cancelling = false
    @State private var confirmCancel = false
    @State private var showAllCopies = false

    private var transfer: BibTransfer { BibTransfer(subdomain: session.library.subdomain, bib: bib) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let status = session.accountStatus(for: bib.id) {
                    AccountStatusTag(status: status)
                }
                holdSection
                if let summary = bib.summary {
                    Text(summary)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                availabilitySection
                detailsSection
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(bib.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: bib.id) {
            pickup = session.patron?.preferredPickup
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
                    Text(subtitle).font(.headline).foregroundStyle(.secondary)
                }
                ForEach(bib.authors.prefix(3), id: \.self) { author in
                    Button(author) { session.runSearch("contributor:(\(author))", searchType: "bl") }
                        .buttonStyle(.borderless)
                        .help("Search for this author")
                }
                Label(session.library.formatName(bib.format), systemImage: "square.stack")
                    .font(.subheadline)
                if let year = bib.displayDate {
                    Text(year).font(.subheadline).foregroundStyle(.secondary)
                }
                if let edition = bib.edition {
                    Text(edition).font(.caption).foregroundStyle(.secondary)
                }
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
                    Label("Sign in to place a hold.", systemImage: "person.crop.circle.badge.questionmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if let hold = session.hold(for: bib.id) {
            VStack(alignment: .leading, spacing: 8) {
                AvailabilityBadge(bib: bib)
                if !hold.canCancel {
                    Label(hold.status == "READY_FOR_PICKUP"
                          ? "This library doesn’t allow cancelling a hold that’s ready for pickup."
                          : "This library doesn’t allow cancelling this hold online.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(role: .destructive) {
                        confirmCancel = true
                    } label: {
                        if cancelling { ProgressView().controlSize(.small) }
                        else { Label("Cancel Hold", systemImage: "xmark.circle") }
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(cancelling)
                    .confirmationDialog("Cancel your hold on “\(bib.title)”?", isPresented: $confirmCancel) {
                        Button("Cancel Hold", role: .destructive) {
                            cancelling = true
                            Task {
                                await session.cancel([hold])
                                cancelling = false
                            }
                        }
                        Button("Keep Hold", role: .cancel) {}
                    } message: {
                        if hold.status == "READY_FOR_PICKUP" {
                            Text("This item is waiting for you. Cancelling releases it to the next person.")
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
                HStack {
                    if !session.locations.isEmpty {
                        Picker("Pick up at", selection: $pickup) {
                            ForEach(session.locations) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .labelsHidden()
                        .lineLimit(1)
                        .fixedSize()
                    }
                    Button {
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
                }
            }
        } else {
            AvailabilityBadge(bib: bib)
        }
    }

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
                                Image(systemName: copy.isAvailable ? "checkmark.circle.fill" : "circle.fill")
                                    .foregroundStyle(StatusColors.copy(copy))
                                    .imageScale(copy.isAvailable ? .medium : .small)
                                Text(copy.branch)
                                    .lineLimit(2)
                                HStack(spacing: 4) {
                                    Text(copy.status).foregroundStyle(StatusColors.copy(copy))
                                    if let due = copy.dueDate {
                                        Text("· due \(DateText.format(due))").foregroundStyle(.secondary)
                                    }
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
