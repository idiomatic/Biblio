import SwiftUI

/// Infinitely scrolling list of items with selection into the inspector.
struct ItemListView<Header: View>: View {
    @Bindable var session: WindowSession
    var model: ItemListModel
    var emptyTitle: String
    var emptySystemImage: String
    @ViewBuilder var header: () -> Header

    @State private var selection = Set<ListEntry.ID>()
    @State private var confirmCancel: [Hold] = []
    /// The selection bar's Cancel button asked, so its dialog appears there.
    @State private var confirmBarCancel = false
    @Environment(\.scenePhase) private var scenePhase
    /// Set in a combined window, where holds choose a card.
    @Environment(\.combinedHolds) private var cards
    /// The titles being given to cards one by one (see `PlaceHoldsView`).
    @State private var assigning: [Bib]?
    #if os(iOS)
    /// Owned here (not by the system Edit button) so window updates can't reset it mid-selection.
    @State private var editMode: EditMode = .inactive
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// Selecting on iPhone, where the item details panel would cover the list: rows only
    /// toggle, and a bottom toolbar holds the actions.
    private var selectingInPlace: Bool {
        #if os(iOS)
        editMode.isEditing && sizeClass == .compact
        #else
        false
        #endif
    }

    /// Only lists with actions for several items at once (holding search results, canceling
    /// holds) select more than one; guests and checked-out items and history select one at a time.
    private var selectsMultiple: Bool {
        guard !session.isGuest else { return false }
        switch model.source {
        case .search, .holds: return true
        case .checkouts, .history: return false
        }
    }

    var body: some View {
        Group {
            if !selectsMultiple {
                List(selection: Binding(get: { selection.first }, set: { selection = Set([$0].compactMap { $0 }) })) { rows }
            } else {
                List(selection: $selection) { rows }
            }
        }
        #if os(iOS)
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        #else
        .listStyle(.inset)
        #endif
        .overlay { emptyState }
        // Only the mask fades; the fresh rows replace the stale ones at once.
        .overlay { refreshMask.animation(.easeInOut(duration: 0.2), value: model.isRefreshing) }
        .refreshable { await refresh() }
        .focusedSceneValue(\.refreshList, RefreshAction { Task { await refresh() } })
        .contextMenu(forSelectionType: ListEntry.ID.self) { ids in
            menu(for: entries(ids))
        }
        .onChange(of: selection) { _, ids in
            if !selectingInPlace { session.select(entries: entries(ids)) }
        }
        #if os(iOS)
        // The inspector is dismissed by a swipe, or by rotating a pad to portrait. Forget the
        // selection then, so tapping the same row shows its details again.
        .onChange(of: session.showInspector) { _, shown in
            if !shown, !editMode.isEditing, !selection.isEmpty { selection = [] }
        }
        #endif
        .task { model.loadIfNeeded() }
        .onChange(of: holdsBorrowedIndexes.map(\.generation)) { model.notBorrowedChanged() }
        // A list left open while the app was in the background may have gone stale.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.loadIfNeeded() }
        }
        .toolbar {
            ListControls(model: model, library: session.library, borrowed: holdsBorrowedIndexes)
            #if os(macOS)
            ToolbarItem { InspectorToggle(session: session) }
            #endif
            #if os(iOS)
            // Multiple selection on iOS/iPadOS happens in edit mode (or with a two-finger drag).
            if selectsMultiple {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    } label: {
                        if editMode.isEditing {
                            Text("Done").fontWeight(.semibold)
                        } else {
                            Label("Select", systemImage: "checkmark.circle.fill")
                        }
                    }
                }
            }
            let selected = entries(selection)
            if selectingInPlace && !(selected.holdable.isEmpty && selected.cancelableHolds.isEmpty) {
                ToolbarItem(placement: .bottomBar) { selectionActions(selected) }
            }
            #endif
        }
        .confirmationDialog(confirmCancel.count == 1 ? "Cancel this hold?" : "Cancel ^[\(confirmCancel.count) hold](inflect: true)?",
                            isPresented: Binding(get: { !confirmCancel.isEmpty }, set: { if !$0 { confirmCancel = [] } }),
                            presenting: confirmCancel) { holds in
            cancelActions(holds)
        }
        .sheet(isPresented: Binding(get: { assigning != nil }, set: { if !$0 { assigning = nil } })) {
            if let cards, let bibs = assigning {
                NavigationStack {
                    ScrollView {
                        PlaceHoldsView(combined: cards, bibs: bibs) {
                            assigning = nil
                            endSelecting()
                        }
                        .padding()
                    }
                    .navigationTitle("Place Holds")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { assigning = nil } }
                    }
                }
            }
        }
    }

    #if os(iOS)
    /// Hold or cancel the selected items, whichever applies; the selection checkmarks show
    /// what's selected.
    private func selectionActions(_ selected: [ListEntry]) -> some View {
        let holdable = selected.holdable
        let cancelable = selected.cancelableHolds
        return HStack {
            if !holdable.isEmpty {
                let title: LocalizedStringKey = "Hold ^[\(holdable.count) Item](inflect: true)"
                if cards != nil {
                    // Which card gets which title is settled in the sheet.
                    Button(title) { assigning = holdable.map(\.bib) }
                } else {
                    Button(title) {
                        Task { await placeHolds(holdable.map(\.bib)) }
                        endSelecting()
                    }
                }
            }
            Spacer()
            if !cancelable.isEmpty {
                Button("Cancel ^[\(cancelable.count) Hold](inflect: true)", role: .destructive) {
                    confirmBarCancel = true
                }
                .tint(.red)
                .confirmationDialog(cancelable.count == 1 ? "Cancel this hold?" : "Cancel ^[\(cancelable.count) hold](inflect: true)?",
                                    isPresented: $confirmBarCancel) {
                    cancelActions(cancelable)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
    }
    #endif

    @ViewBuilder
    private func cancelActions(_ holds: [Hold]) -> some View {
        Button(holds.count == 1 ? "Cancel Hold" : "Cancel ^[\(holds.count) Hold](inflect: true)", role: .destructive) {
            Task { await session.cancel(holds) }
            let canceled = Set(holds.map(\.id))
            selection.subtract(model.entries.filter { $0.hold.map { canceled.contains($0.id) } ?? false }.map(\.id))
            confirmCancel = []
            endSelecting()
        }
        Button(holds.count == 1 ? "Keep Hold" : "Keep Holds", role: .cancel) { confirmCancel = [] }
    }

    /// Holds for the selected items: on each title's default card in a combined window.
    private func placeHolds(_ bibs: [Bib]) async {
        if let cards { await cards.placeHolds(bibs, target: .auto) } else { await session.placeHolds(bibs) }
    }

    /// The indexes the holds list's "Not Borrowed" filter uses.
    private var holdsBorrowedIndexes: [BorrowedIndex] {
        guard model.source == .holds, !session.isGuest else { return [] }
        return cards?.borrowedIndexes ?? [session.borrowed]
    }

    /// Reloads the list and the open item's details, which may have changed with it.
    private func refresh() async {
        session.detailsRevision += 1
        await model.refresh()
        if !model.source.isSearch { session.syncBorrowed() }
    }

    private func endSelecting() {
        #if os(iOS)
        guard selectingInPlace else { return }
        selection = []
        withAnimation { editMode = .inactive }
        #endif
    }

    @ViewBuilder
    private var rows: some View {
        header()
        // One concrete row type: a `switch` here makes the rows heterogeneous, and SwiftUI then
        // collects the IDs of thousands of rows on a slow path at every section change.
        ForEach(model.rows) { row in
            ListRow(row: row, model: model, library: session.library,
                    isSelected: selection.contains(row.id)) { confirmCancel = [$0] }
        }
        footer
    }

    @ViewBuilder
    private var footer: some View {
        // Pages fetched mid-list show as placeholders filling in; the footer spinner is only
        // for the first page and for background fetching behind a client sort.
        if (model.isLoading && !model.loaded) || model.isBackgroundFetching {
            HStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                if model.isBackgroundFetching {
                    Text("Loading… \(model.entries.count) of \(model.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .listRowSeparator(.hidden)
        } else if let error = model.error {
            HStack {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Retry") { model.retry() }
            }
        }
    }

    /// Dims the stale rows while a refresh fetches their replacements. On iOS the pull-to-refresh
    /// control is the spinner.
    @ViewBuilder
    private var refreshMask: some View {
        if model.isRefreshing {
            Rectangle()
                .fill(.background.opacity(0.5))
                #if os(macOS)
                .overlay { ProgressView().controlSize(.small) }
                #endif
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if case .search(let q) = model.source, q.isEmpty {
            EmptyView()
        } else if model.entries.isEmpty && !model.isLoading && model.error == nil && model.loaded {
            ContentUnavailableView(emptyTitle, systemImage: emptySystemImage)
        } else if model.rows.isEmpty && !model.entries.isEmpty && !model.isBackgroundFetching {
            ContentUnavailableView("No Matching Items", systemImage: "line.3.horizontal.decrease.circle", description: Text("Try a different filter."))
        }
    }

    /// Selected entries in list order.
    private func entries(_ ids: Set<ListEntry.ID>) -> [ListEntry] {
        model.entries.filter { ids.contains($0.id) }
    }

    @ViewBuilder
    private func menu(for selected: [ListEntry]) -> some View {
        let holdable = selected.filter { $0.kind == .catalog && $0.bib.holdable && $0.accountStatus == nil }
        let cancelable = selected.compactMap(\.hold).filter(\.canCancel)
        if selected.count == 1, let entry = selected.first {
            Button("Show Details", systemImage: "info.circle") { session.select(entry.bib) }
        }
        if !holdable.isEmpty && !session.isGuest {
            Button(holdable.count == 1 ? "Hold" : "Hold ^[\(holdable.count) Item](inflect: true)", systemImage: "tray.and.arrow.down") {
                Task { await placeHolds(holdable.map(\.bib)) }
            }
        }
        if !cancelable.isEmpty {
            Button(cancelable.count == 1 ? "Cancel Hold…" : "Cancel ^[\(cancelable.count) Hold](inflect: true)…",
                   systemImage: "xmark.circle", role: .destructive) { confirmCancel = cancelable }
        }
        if selected.count == 1, let entry = selected.first {
            Button("Search for This Title", systemImage: "magnifyingglass") {
                session.runSearch(entry.bib.searchText)
            }
            if let url = URL(string: "\(session.library.baseURL.absoluteString)/v2/record/\(entry.bib.id)") {
                ShareLink("Share", item: url)
            }
        }
    }
}

extension ItemListView where Header == EmptyView {
    init(session: WindowSession, model: ItemListModel, emptyTitle: String, emptySystemImage: String) {
        self.init(session: session, model: model, emptyTitle: emptyTitle, emptySystemImage: emptySystemImage) { EmptyView() }
    }
}

/// A row's background, tinted by the account's status. On iPhone and iPad it is inset and
/// rounded, selection included, like the sidebar's: iPadOS mirrors the content column's edges
/// under the floating sidebar and inspector, so a full-width fill would smear into both.
/// macOS's inset list keeps the system highlight.
struct RowBackground: View {
    var isSelected: Bool
    var tint: Color?

    var body: some View {
        #if os(iOS)
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle((tint ?? .clear).opacity(0.08)))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
        #else
        if !isSelected, let tint { tint.opacity(0.08) }
        #endif
    }
}

extension View {
    /// Keeps a row's own text colors when selected: on iPhone and iPad, `RowBackground`'s light
    /// highlight replaces the dark system one that the list's white text was for.
    func rowForeground() -> some View {
        #if os(iOS)
        foregroundStyle(Color.primary)
            .environment(\.backgroundProminence, .standard)
        #else
        self
        #endif
    }
}

/// A list row: a fetched item, or the placeholder for one not fetched yet.
private struct ListRow: View {
    var row: ItemListModel.Row
    var model: ItemListModel
    var library: LibraryInfo
    var isSelected: Bool
    var confirmCancel: (Hold) -> Void
    @Environment(\.combinedHolds) private var cards

    /// The status that tints the row: the first card's, in a window with several cards.
    private var tint: AccountStatus? {
        guard let entry = row.entry else { return nil }
        if let cards, entry.kind == .catalog { return cards.statuses(for: entry.bib.id).first?.status }
        return entry.accountStatus
    }

    // Every row has the same shape and modifiers (items and placeholders alike), so SwiftUI
    // can identify the rows of a long list cheaply.
    var body: some View {
        ZStack {
            switch row {
            case .item(let entry): ItemRow(entry: entry, library: library)
            case .placeholder: PlaceholderRow()
            }
        }
        .rowForeground()
        .tag(row.id)
        .selectionDisabled(row.entry == nil)
        .listRowBackground(RowBackground(isSelected: isSelected, tint: tint.map(StatusColors.account)))
        .onAppear {
            switch row {
            case .item(let entry): model.itemAppeared(entry)
            case .placeholder(let position): model.placeholderAppeared(position)
            }
        }
        .onDisappear {
            if case .placeholder(let position) = row { model.placeholderDisappeared(position) }
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

extension ItemListModel.Row {
    /// The fetched entry, if this row is one.
    fileprivate var entry: ListEntry? {
        if case .item(let entry) = self { entry } else { nil }
    }
}

/// Sort and format-filter menus.
struct ListControls: ToolbarContent {
    var model: ItemListModel
    var library: LibraryInfo
    /// The cards' indexes for the "Not Borrowed" filter (holds); none hides it.
    var borrowed: [BorrowedIndex] = []

    private var filtered: Bool { model.format != nil || !model.notBorrowed.isEmpty }

    var body: some ToolbarContent {
        ToolbarItemGroup {
            if !model.source.isSearch {
            Menu {
                Picker("Format", selection: Binding(get: { model.format }, set: { model.setFormat($0) })) {
                    Text("All Formats").tag(String?.none)
                    ForEach(model.formatChoices, id: \.value) { choice in
                        Text("\(library.formatName(choice.value)) (\(choice.count))").tag(Optional(choice.value))
                    }
                }
                .pickerStyle(.inline)
                if !borrowed.isEmpty, borrowed.allSatisfy(\.isComplete) || !model.notBorrowed.isEmpty {
                    Divider()
                    Toggle("Not Borrowed", isOn: Binding(get: { !model.notBorrowed.isEmpty },
                                                         set: { model.setNotBorrowed($0 ? borrowed : []) }))
                }
            } label: {
                Label("Format", systemImage: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .help("Filter by format")
            .disabled(model.formatChoices.isEmpty && model.format == nil && borrowed.isEmpty)
            }

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
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Change sort order")
        }
    }
}

struct ItemRow: View {
    var entry: ListEntry
    var library: LibraryInfo
    /// The card whose hold, checkout, or history this row is, in a list of several cards' rows.
    var login: Int? = nil
    /// In a window with several cards, a catalog row marks each card's hold or checkout.
    @Environment(\.combinedHolds) private var cards
    @Environment(\.borrowedIndex) private var borrowedIndex

    private var bib: Bib { entry.bib }

    /// Borrowed before (catalog and hold rows): by any card in a window with several.
    private var borrowed: BorrowedIndex.Match? {
        switch entry.kind {
        case .catalog, .hold: break
        case .checkout, .history: return nil
        }
        if let cards { return cards.borrowed(for: bib).first?.match }
        return borrowedIndex?.match(bib)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverImage(url: bib.jacketSmall, format: bib.format)
                .frame(width: 56, height: 80)
            VStack(alignment: .leading, spacing: 3) {
                Text(bib.title)
                    .font(.headline)
                    .lineLimit(2)
                if let subtitle = bib.subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                if let author = bib.primaryAuthor {
                    Text(author).font(.callout).lineLimit(1)
                }
                Text(details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                status
            }
            Spacer(minLength: 0)
            cardChips
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// In a window with several cards, the chip of the card whose row this is, or of each card
    /// that holds or borrowed a catalog row's title (in the order of their tags), at the top right.
    private var chipLogins: [Int] {
        guard let cards else { return [] }
        if let login { return [login] }
        if case .catalog = entry.kind { return cards.statuses(for: bib.id).map(\.login) }
        return []
    }

    @ViewBuilder
    private var cardChips: some View {
        if let cards, !chipLogins.isEmpty {
            VStack(spacing: 4) {
                ForEach(chipLogins, id: \.self) { login in
                    CardChip(style: cards.style(login))
                        .help(cards.name(login))
                }
            }
            .padding(.top, 6)
        }
    }

    /// Format, year and edition, e.g. "Book · 2019 · Second Ace hardcover edition".
    private var details: String {
        [library.formatName(bib.format), bib.displayDate, bib.edition]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private var status: some View {
        switch entry.kind {
        case .catalog:
            AvailabilityBadge(bib: bib, borrowed: borrowed.map { BorrowedMark(match: $0, library: library) })
            if let cards {
                let marks = cards.statuses(for: bib.id)
                if !marks.isEmpty {
                    // Each card's chip is at the row's top right (`cardChips`).
                    WrapLayout(spacing: 6, lineSpacing: 2) {
                        ForEach(marks, id: \.login) { mark in
                            AccountStatusTag(status: mark.status, hold: cards.sessions[mark.login].hold(for: bib.id))
                        }
                    }
                }
            } else if let status = entry.catalogStatus {
                AccountStatusTag(status: status, hold: entry.catalogHold)
            }
        case .hold(let h):
            // As a catalog row: the title's availability, then the hold, as item detail shows them.
            AvailabilityBadge(bib: bib, borrowed: borrowed.map { BorrowedMark(match: $0, library: library) })
            // The pickup location is in item detail.
            AccountStatusTag(status: .onHold(ready: h.isReady, position: h.position), hold: h)
        case .checkout(let c):
            if let due = c.dueDate {
                HStack(spacing: 4) {
                    Image(systemName: "calendar").imageScale(.small)
                    Text("Due \(DateText.format(due))")
                }
                .font(.callout)
                .foregroundStyle(DateText.isPast(due) ? .red : .secondary)
            }
        case .history(let h):
            if let d = h.checkoutDate ?? h.returnedDate {
                Text("Borrowed \(DateText.format(d))").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// Lays its children out left to right, starting a new line when the next would overflow; a child
/// wider than a line is squeezed to fit (so a long, single-line `Text` truncates).
struct WrapLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = arrange(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, placed.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width { size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            // Empty children (such as an absent note) take no room.
            if size == .zero { frames.append(CGRect(x: x, y: y, width: 0, height: 0)); continue }
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (frames, CGSize(width: widest, height: y + lineHeight))
    }
}

/// Stand-in for an item whose page hasn't been fetched yet, sized like an `ItemRow`
/// so the scroll bar reflects the whole list.
struct PlaceholderRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(width: 56, height: 80)
            VStack(alignment: .leading, spacing: 6) {
                Text("Loading title placeholder").font(.headline)
                Text("Author name").font(.callout)
                Text("Format · 2000").font(.callout)
            }
            .redacted(reason: .placeholder)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityLabel("Loading")
    }
}

struct AvailabilityBadge: View {
    var bib: Bib
    /// A list row's "borrowed before" mark, last on the line.
    var borrowed: BorrowedMark? = nil

    var body: some View {
        // The pieces wrap as whole items on a narrow screen.
        WrapLayout(spacing: 8, lineSpacing: 2) {
            switch bib.status {
            case "AVAILABLE":
                badge("Available", "checkmark.circle.fill")
            case "ON_ORDER":
                badge("On order", "shippingbox")
            case "UNAVAILABLE", "NOT_AVAILABLE":
                badge("All copies in use", "clock")
            case .some(let s):
                Text(s.prettified).foregroundStyle(.secondary)
            case nil:
                EmptyView()
            }
            if bib.status != "ON_ORDER" { OnOrderNote(bib: bib) }
            if bib.heldCopies > 0 || bib.totalCopies > 0 {
                HStack(spacing: 3) {
                    Image(systemName: bib.heldCopies > 0 ? "person.2" : "books.vertical").imageScale(.small)
                    Text(peopleWaiting)
                }
                .foregroundStyle(.secondary)
                .fixedSize()
            }
            if let borrowed { borrowed }
        }
        .font(.callout)
        .labelStyle(.titleAndIcon)
    }

    /// A plain icon and text, not a `Label`, which inside a List row spaces the two far apart.
    private func badge(_ text: String, _ symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
        }
        .foregroundStyle(StatusColors.availability(bib.status))
        .fixedSize()
    }

    private var peopleWaiting: String {
        let copies = inflected("^[\(bib.totalCopies) copy](inflect: true)")
        let waiting = inflected("^[\(bib.heldCopies) hold](inflect: true)")
        // Only what's there to say: no holds, just the copies; no copies yet, just the holds.
        if bib.heldCopies == 0 { return copies }
        if bib.totalCopies == 0 { return waiting }
        return String(localized: "\(waiting) on \(copies)")
    }
}

/// "On order" when the title has no copies yet, or "N on order" when more copies are coming.
struct OnOrderNote: View {
    var bib: Bib

    var body: some View {
        if let text {
            // Plain HStack rather than Label: inside a List row's HStack, an automatic-style
            // Label could collapse to its icon and inflate the row height.
            HStack(spacing: 3) {
                Image(systemName: "shippingbox").imageScale(.small)
                Text(text)
            }
            .foregroundStyle(StatusColors.availability("ON_ORDER"))
            .fixedSize()
        }
    }

    private var text: String? {
        if bib.status == "ON_ORDER" { return "On order" }
        if bib.onOrderCopies > 0 { return "\(bib.onOrderCopies) on order" }
        return nil
    }
}

struct CoverImage: View {
    var url: URL?
    var format: String

    var body: some View {
        // The placeholder sits underneath: Syndetics answers "no cover" with a tiny
        // transparent GIF, which then simply lets the placeholder show through.
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .overlay {
                    Image(systemName: symbol)
                        .foregroundStyle(.secondary)
                }
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Color.clear
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch format {
        case "DVD", "BLURAY", "UK", "VIDEO_ONLINE", "DVD_PBLURAY": "film"
        case "MUSIC_CD": "music.note"
        case "AB", "BOOK_CD", "PLAYAWAY_AUDIOBOOK": "headphones"
        case "EBOOK": "ipad"
        case "VIDEO_GAME": "gamecontroller"
        case "BOARD_GAME": "die.face.5"
        case "MAG", "MAG_ONLINE", "NEWSPAPER": "newspaper"
        default: "book.closed"
        }
    }
}

nonisolated enum DateText {
    /// Local midnight of an ISO date ("2026-03-14…").
    static func date(_ s: String) -> Date? { date(s, in: .current) }

    /// Days since 1970-01-01 of an ISO date, or 0.
    static func dayNumber(_ s: String) -> Int {
        guard let utc = TimeZone(identifier: "UTC"), let d = date(s, in: utc) else { return 0 }
        return Int(d.timeIntervalSince1970 / 86400)
    }

    private static func date(_ s: String, in zone: TimeZone) -> Date? {
        let parts = s.prefix(10).split(separator: "-", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }

    static func format(_ s: String) -> String {
        date(s)?.formatted(date: .abbreviated, time: .omitted) ?? s
    }

    static func isPast(_ s: String) -> Bool {
        guard let d = date(s) else { return false }
        return d < Calendar.current.startOfDay(for: .now)
    }
}
