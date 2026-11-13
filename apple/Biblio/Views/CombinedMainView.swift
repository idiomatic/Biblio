import SwiftUI

/// A combined window's cards, for the list actions that place holds.
private struct CombinedHoldsKey: EnvironmentKey {
    static let defaultValue: CombinedSession? = nil
}

extension EnvironmentValues {
    var combinedHolds: CombinedSession? {
        get { self[CombinedHoldsKey.self] }
        set { self[CombinedHoldsKey.self] = newValue }
    }
}

/// A card's monogram in its color, marking whose item a row is.
struct CardChip: View {
    var style: CardStyle
    var size: CGFloat = 18

    var body: some View {
        Text(style.monogram)
            .font(.system(size: size * 0.6, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(style.color, in: Circle())
            .accessibilityHidden(true)
    }
}

/// The window of a library's cards combined: holds, checked out items, and history interlaced,
/// with the catalog (search, new titles) on the first card.
struct CombinedMainView: View {
    @Bindable var combined: CombinedSession
    var scope: CardScope?
    var signOut: () -> Void

    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @State private var preferredColumn: NavigationSplitViewColumn
    @State private var holdsDropTargeted = false

    init(combined: CombinedSession, scope: CardScope?, signOut: @escaping () -> Void, startOnSidebar: Bool = false) {
        self.combined = combined
        self.scope = scope
        self.signOut = signOut
        _preferredColumn = State(initialValue: startOnSidebar ? .sidebar : .detail)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredColumn) {
            sidebar
        } detail: {
            NavigationStack { detail }
        }
        .modifier(ItemInspector(isPresented: inspectorShown) { inspector.id(ObjectIdentifier(combined.active)) })
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .principal) {
                SearchField(session: combined.primary)
                    .frame(width: 280)
            }
            #endif
        }
        .overlay(alignment: .bottom) { BannerView(session: combined.active) }
        .modifier(StatusBarPlacement(status: combined.primary.client.status))
        .navigationTitle(combined.library.shortName ?? combined.library.name)
        #if os(macOS)
        .navigationSubtitle("All Cards")
        #endif
        .environment(\.combinedHolds, combined)
        .focusedSceneValue(\.addAnother, combined.windowActions.map { RefreshAction(perform: $0.addCard) })
        .task { await combined.start() }
        .task(id: combined.section) {
            if combined.section == .search || combined.section == .newTitles { await combined.loadAccountLists() }
        }
        .tint(combined.library.tint)
    }

    private var inspectorShown: Binding<Bool> {
        Binding(get: { combined.active.showInspector }, set: { combined.active.showInspector = $0 })
    }

    private var inspector: some View {
        Group {
            if combined.active.selectedEntries.count > 1 {
                MultiSelectionView(session: combined.active, entries: combined.active.selectedEntries, cards: combined)
            } else if let bib = combined.active.selection {
                ItemDetailView(session: combined.active, bib: bib, cards: combined)
                    .id(bib.id)
            } else {
                ContentUnavailableView("No Selection", systemImage: "book.closed",
                                       description: Text("Select an item to see its details and availability."))
            }
        }
        .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $combined.section) {
            if let scope {
                CardsSection(scope: scope)
            }
            Section("Catalog", isExpanded: LibraryStore.shared.sidebarSection("Catalog", in: combined.library.subdomain)) {
                sidebarRow(.search)
                sidebarRow(.newTitles)
            }
            Section("My Library", isExpanded: LibraryStore.shared.sidebarSection("My Library", in: combined.library.subdomain)) {
                // An item dropped on Holds is held for each title's default card.
                sidebarRow(.holds)
                    .onDrop(of: [.biblioItem], isTargeted: $holdsDropTargeted) { providers in
                        BibTransfer.load(from: providers) { item in
                            Task { await combined.placeHolds([item.bib], target: .auto) }
                        }
                    }
                    .listRowBackground(holdsDropTargeted ? Color.accentColor.opacity(0.25) : nil)
                sidebarRow(.checkouts)
                sidebarRow(.history)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { VersionLabel() }
        .navigationTitle(combined.library.shortName ?? "Library")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 190, ideal: 230)
        #endif
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .navigation) { LibrariesBackButton(action: signOut) }
            #else
            ToolbarItem(placement: .topBarLeading) { LibrariesBackButton(action: signOut) }
            ToolbarItem(placement: .topBarTrailing) { LibraryCardButton(session: combined.cardSession) }
            #endif
        }
    }

    private func sidebarRow(_ section: AppSection) -> some View {
        NavigationLink(value: section) {
            if section == .history {
                HistorySidebarLabel(indexes: combined.borrowedIndexes)
            } else {
                Label(section.title, systemImage: section.systemImage)
                    .badge(badge(for: section))
            }
        }
    }

    /// The sum over the shown cards.
    private func badge(for section: AppSection) -> Int {
        guard let model = combined.list(for: section), section != .history else { return 0 }
        return model.loaded ? model.total : 0
    }

    @ViewBuilder
    private var detail: some View {
        switch combined.section ?? .holds {
        case .search: SearchView(session: combined.primary)
        case .newTitles: NewTitlesView(session: combined.primary)
        case .holds: CombinedListView(combined: combined, section: .holds, model: combined.holds)
        case .checkouts: CombinedListView(combined: combined, section: .checkouts, model: combined.checkouts)
        case .history: CombinedListView(combined: combined, section: .history, model: combined.history)
        case .account(let user):
            // One view whether the card is on or off, so switching it keeps the page (and its scroll).
            AccountView(library: combined.library, username: user, session: combined.sessions.first { $0.username == user },
                        actions: combined.windowActions, isBusy: scope?.isBusy(user) ?? false)
                .id(user)
        }
    }
}

/// One of the account lists, interlaced across the shown cards.
struct CombinedListView: View {
    @Bindable var combined: CombinedSession
    var section: AppSection
    var model: MergedListModel

    @State private var selection: MergedListModel.Row.ID?
    @State private var dropTargeted = false
    @State private var confirmCancel: (hold: Hold, login: Int)?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let rows = model.rows
        List(selection: $selection) {
            if section == .holds {
                HoldFilterBar(model: model)
                    // Matches the space above the bar, which the list's top margin adds.
                    #if os(macOS)
                    .padding(.bottom, 10)
                    #else
                    .padding(.bottom, 16)
                    #endif
                    .listRowSeparator(.hidden)
            }
            ForEach(rows) { row in
                CombinedRow(combined: combined, model: model, row: row, isSelected: selection == row.id) {
                    confirmCancel = ($0, row.login)
                }
            }
            footer
        }
        #if os(iOS)
        .listStyle(.plain)
        #else
        .listStyle(.inset)
        #endif
        .overlay { emptyState }
        .refreshable { await refresh() }
        .focusedSceneValue(\.refreshList, RefreshAction { Task { await refresh() } })
        .onChange(of: selection) { _, id in
            if let row = rows.first(where: { $0.id == id }) { combined.select(row) }
        }
        .task { model.loadIfNeeded() }
        .onChange(of: combined.borrowedIndexes.map(\.generation)) { model.notBorrowedChanged() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.loadIfNeeded() }
        }
        .toolbar {
            CombinedControls(model: model, library: combined.library,
                             borrowed: section == .holds ? combined.borrowedIndexes : [])
            #if os(macOS)
            ToolbarItem { InspectorToggle(session: combined.active) }
            #endif
        }
        .navigationTitle(section.title)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: section == .holds ? [.biblioItem] : [],
                isTargeted: Binding(get: { dropTargeted }, set: { dropTargeted = section == .holds && $0 })) { providers in
            BibTransfer.load(from: providers) { item in
                Task { await combined.placeHolds([item.bib], target: .auto) }
            }
        }
        .confirmationDialog("Cancel this hold?", isPresented: Binding(get: { confirmCancel != nil }, set: { if !$0 { confirmCancel = nil } }),
                            presenting: confirmCancel) { target in
            Button("Cancel Hold", role: .destructive) {
                Task { await combined.cancel([target.hold], login: target.login) }
                confirmCancel = nil
            }
            Button("Keep Hold", role: .cancel) { confirmCancel = nil }
        } message: { target in
            Text("On \(combined.name(target.login))’s card.")
        }
    }

    private func refresh() async {
        for s in combined.sessions { s.detailsRevision += 1 }
        await model.refresh()
        for s in combined.sessions { s.syncBorrowed() }
    }

    @ViewBuilder
    private var footer: some View {
        if model.isLoading || model.isBackgroundFetching {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                if model.isBackgroundFetching {
                    Text("Loading… \(model.loadedCount) of \(model.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .listRowSeparator(.hidden)
        } else if let error = model.error {
            HStack {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                Spacer()
                Button("Retry") { model.retry() }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isEmpty && model.error == nil {
            ContentUnavailableView(emptyTitle, systemImage: section.systemImage)
        } else if model.loaded && !model.isBackgroundFetching && model.error == nil && !model.rows.contains(where: { $0.entry != nil }) {
            ContentUnavailableView("No Matching Items", systemImage: "line.3.horizontal.decrease.circle", description: Text("Try a different filter."))
        }
    }

    private var emptyTitle: String {
        switch section {
        case .holds: "No Holds"
        case .checkouts: "Nothing Checked Out"
        default: "No Borrowing History"
        }
    }
}

private struct CombinedRow: View {
    var combined: CombinedSession
    var model: MergedListModel
    var row: MergedListModel.Row
    var isSelected: Bool
    var confirmCancel: (Hold) -> Void

    var body: some View {
        ZStack {
            if let entry = row.entry {
                ItemRow(entry: entry, library: combined.library, login: row.login)
            } else {
                PlaceholderRow()
            }
        }
        .rowForeground()
        .tag(row.id)
        .selectionDisabled(row.entry == nil)
        .listRowBackground(RowBackground(isSelected: isSelected, tint: row.entry?.accountStatus.map(StatusColors.account)))
        .onAppear {
            if row.entry != nil { model.itemAppeared(row) } else { model.placeholderAppeared(row) }
        }
        .onDisappear { model.placeholderDisappeared(row) }
        .contextMenu {
            if case .hold(let h)? = row.entry?.kind, h.canCancel {
                Button("Cancel Hold…", systemImage: "xmark.circle", role: .destructive) { confirmCancel(h) }
            }
        }
        #if os(iOS)
        .swipeActions {
            if case .hold(let h)? = row.entry?.kind, h.canCancel {
                Button("Cancel Hold", systemImage: "xmark", role: .destructive) { confirmCancel(h) }
            }
        }
        #endif
    }
}

/// Format and sort menus for a merged list, as a card's own list has; holds filter by status in
/// the list's `HoldFilterBar`.
private struct CombinedControls: ToolbarContent {
    var model: MergedListModel
    var library: LibraryInfo
    /// The cards' indexes for the holds' "Not Borrowed" filter; none hides it.
    var borrowed: [BorrowedIndex] = []

    private var filtered: Bool { model.format != nil || model.isNotBorrowed }

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Picker("Format", selection: Binding(get: { model.format }, set: { model.setFormat($0) })) {
                    Text("All Formats").tag(String?.none)
                    ForEach(model.formatChoices, id: \.value) { choice in
                        Text("\(library.formatName(choice.value)) (\(choice.count))").tag(Optional(choice.value))
                    }
                }
                .pickerStyle(.inline)
                if !borrowed.isEmpty, borrowed.allSatisfy(\.isComplete) || model.isNotBorrowed {
                    Divider()
                    Toggle("Not Borrowed", isOn: Binding(get: { model.isNotBorrowed },
                                                         set: { model.setNotBorrowed($0 ? borrowed : []) }))
                }
            } label: {
                Label("Format", systemImage: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .help("Filter by format")
            .disabled(model.formatChoices.isEmpty && model.format == nil && borrowed.isEmpty)

            Menu {
                Picker("Sort By", selection: Binding(get: { model.sort }, set: { model.setSort($0) })) {
                    ForEach(model.serverSorts, id: \.self) { s in
                        Text(library.sortName(s)).tag(ItemListModel.Sort.server(s))
                    }
                    Divider()
                    Text("People Waiting").tag(ItemListModel.Sort.peopleWaiting)
                    if !model.serverSorts.contains("title") {
                        Text("Title").tag(ItemListModel.Sort.clientTitle)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(model.isBackgroundFetching ? "Sort (loading all cards…)" : "Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Change sort order")
        }
    }
}


/// An item's hold controls in a combined window: each card's hold or checkout with its own
/// Cancel Hold, and "Hold for <card>" for the cards that can still hold it, each at its
/// preferred pickup location.
struct CardsHoldSection: View {
    var combined: CombinedSession
    var bib: Bib

    @State private var placing = false
    @State private var canceling: Int?
    @State private var confirmCancel: Int?
    /// Cancel Hold's height, which a hold's status line takes whether the button is beside it or
    /// below it, so the status stays put as the inspector narrows.
    @State private var cancelHeight: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AvailabilityBadge(bib: bib)
            ForEach(combined.sessions.indices, id: \.self) { login in
                if let hold = combined.sessions[login].hold(for: bib.id) {
                    holdRow(login, hold)
                } else if let status = combined.sessions[login].accountStatus(for: bib.id) {
                    HStack {
                        CardChip(style: combined.style(login))
                        AccountStatusTag(status: status, hold: combined.sessions[login].hold(for: bib.id))
                    }
                }
            }
            if bib.holdable, let login = combined.cardForHold(bib) {
                splitHoldButton(default: login)
            }
        }
    }

    private func holdRow(_ login: Int, _ hold: Hold) -> some View {
        let lineHeight = hold.canCancel ? cancelHeight : nil
        let status = AccountStatusTag(status: .onHold(ready: hold.isReady, position: hold.position), hold: hold)
            .frame(minHeight: lineHeight)
        return HStack(alignment: .top, spacing: 8) {
            CardChip(style: combined.style(login))
                .frame(minHeight: lineHeight)
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        status
                        Spacer(minLength: 0)
                        cancelButton(login, hold)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        status
                        cancelButton(login, hold)
                    }
                }
                PickupLine(hold: hold)
            }
        }
    }

    @ViewBuilder
    private func cancelButton(_ login: Int, _ hold: Hold) -> some View {
        let session = combined.sessions[login]
        if hold.canCancel {
            Button(role: .destructive) {
                confirmCancel = login
            } label: {
                if canceling == login { ProgressView().controlSize(.small) }
                else { Label("Cancel Hold", systemImage: "xmark.circle").fixedSize() }
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(canceling != nil)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cancelHeight = $0 }
            .confirmationDialog("Cancel \(combined.name(login))’s hold on “\(bib.title)”?",
                                isPresented: Binding(get: { confirmCancel == login }, set: { if !$0 { confirmCancel = nil } })) {
                Button("Cancel Hold", role: .destructive) {
                    canceling = login
                    Task {
                        await session.cancel([hold])
                        canceling = nil
                    }
                }
                Button("Keep Hold", role: .cancel) {}
            }
        }
    }

    /// "Hold for <card>" for the default card, with a drop-down to hold for another card at once.
    private func splitHoldButton(default login: Int) -> some View {
        let able = combined.cardsAbleToHold(bib)
        return HStack(spacing: 0) {
            Button { place(for: login, default: login) } label: {
                HStack(spacing: 6) {
                    if placing {
                        ProgressView().controlSize(.small)
                    } else {
                        CardChip(style: combined.style(login), size: 16)
                            .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1))
                        Text("Hold for \(combined.name(login))").lineLimit(1)
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, able.count > 1 ? 8 : 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if able.count > 1 {
                Rectangle().fill(.white.opacity(0.45)).frame(width: 1, height: 18)
                Menu {
                    // The default card is the button itself.
                    ForEach(able.filter { $0 != login }, id: \.self) { card in
                        Button("Hold for \(combined.name(card))") { place(for: card, default: login) }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .accessibilityLabel("Hold for another card")
            }
        }
        .foregroundStyle(.white)
        .background(Color.accentColor, in: Capsule())
        .fixedSize()
        .disabled(placing)
    }

    /// Places the hold on `card`, which becomes the default for the next one.
    private func place(for card: Int, default login: Int) {
        let session = combined.sessions[card]
        placing = true
        combined.stickyCard = card
        Task {
            await session.placeHold(bib)
            placing = false
        }
    }
}
