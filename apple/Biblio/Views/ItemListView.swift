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
        // A list left open while the app was in the background may have gone stale.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.loadIfNeeded() }
        }
        .toolbar {
            ListControls(model: model, library: session.library)
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
        .confirmationDialog(confirmCancel.count == 1 ? "Cancel this hold?" : "Cancel \(confirmCancel.count) holds?",
                            isPresented: .constant(!confirmCancel.isEmpty), presenting: confirmCancel) { holds in
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
                let title = holdable.count == 1 ? "Hold 1 Item" : "Hold \(holdable.count) Items"
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
                Button(cancelable.count == 1 ? "Cancel 1 Hold" : "Cancel \(cancelable.count) Holds", role: .destructive) {
                    confirmBarCancel = true
                }
                .tint(.red)
                .confirmationDialog(cancelable.count == 1 ? "Cancel this hold?" : "Cancel \(cancelable.count) holds?",
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
        Button(holds.count == 1 ? "Cancel Hold" : "Cancel \(holds.count) Holds", role: .destructive) {
            Task { await session.cancel(holds) }
            selection.subtract(holds.map { "hold-\($0.id)" })
            confirmCancel = []
            endSelecting()
        }
        Button(holds.count == 1 ? "Keep Hold" : "Keep Holds", role: .cancel) { confirmCancel = [] }
    }

    /// Holds for the selected items: on each title's default card in a combined window.
    private func placeHolds(_ bibs: [Bib]) async {
        if let cards { await cards.placeHolds(bibs, target: .auto) } else { await session.placeHolds(bibs) }
    }

    /// Reloads the list and the open item's details, which may have changed with it.
    private func refresh() async {
        session.detailsRevision += 1
        await model.refresh()
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
            Button(holdable.count == 1 ? "Hold" : "Hold \(holdable.count) Items", systemImage: "tray.and.arrow.down") {
                Task { await placeHolds(holdable.map(\.bib)) }
            }
        }
        if !cancelable.isEmpty {
            Button(cancelable.count == 1 ? "Cancel Hold…" : "Cancel \(cancelable.count) Holds…",
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

/// A list row: a fetched item, or the placeholder for one not fetched yet.
private struct ListRow: View {
    var row: ItemListModel.Row
    var model: ItemListModel
    var library: LibraryInfo
    var isSelected: Bool
    var confirmCancel: (Hold) -> Void

    // Every row has the same shape and modifiers (items and placeholders alike), so SwiftUI
    // can identify the rows of a long list cheaply.
    var body: some View {
        ZStack {
            switch row {
            case .item(let entry): ItemRow(entry: entry, library: library)
            case .placeholder: PlaceholderRow()
            }
        }
        .tag(row.id)
        .selectionDisabled(row.entry == nil)

        // Tint by this account's status; selected rows keep the system highlight.
        .listRowBackground(isSelected ? nil : row.entry?.accountStatus.map { StatusColors.account($0).opacity(0.08) })
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
            } label: {
                Label("Format", systemImage: model.format == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .help("Filter by format")
            .disabled(model.formatChoices.isEmpty && model.format == nil)
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

    private var bib: Bib { entry.bib }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverImage(url: bib.jacketSmall, format: bib.format)
                .frame(width: 48, height: 68)
            VStack(alignment: .leading, spacing: 3) {
                Text(bib.title)
                    .font(.headline)
                    .lineLimit(2)
                if let subtitle = bib.subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if let author = bib.primaryAuthor {
                    Text(author).font(.subheadline).lineLimit(1)
                }
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                status
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
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
            AvailabilityBadge(bib: bib)
            if let status = entry.catalogStatus { AccountStatusTag(status: status) }
        case .hold(let h):
            // Items wrap onto further lines on a narrow screen instead of squeezing each other.
            WrapLayout(spacing: 6, lineSpacing: 2) {
                HoldStatusBadge(hold: h).fixedSize()
                OnOrderNote(bib: bib)
                if let p = h.position { Text("#\(p) in line").foregroundStyle(.secondary).fixedSize() }
                if let loc = h.pickupLocation {
                    HStack(spacing: 2) {
                        Image(systemName: "mappin").imageScale(.small)
                        Text(loc).lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        case .checkout(let c):
            if let due = c.dueDate {
                HStack(spacing: 4) {
                    Image(systemName: "calendar").imageScale(.small)
                    Text("Due \(DateText.format(due))")
                }
                .font(.caption)
                .foregroundStyle(DateText.isPast(due) ? .red : .secondary)
            }
        case .history(let h):
            if let d = h.checkoutDate ?? h.returnedDate {
                Text("Borrowed \(DateText.format(d))").font(.caption).foregroundStyle(.secondary)
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
                .frame(width: 48, height: 68)
            VStack(alignment: .leading, spacing: 6) {
                Text("Loading title placeholder").font(.headline)
                Text("Author name").font(.subheadline)
                Text("Format · 2000").font(.caption)
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
        }
        .font(.caption)
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
        let copies = bib.totalCopies == 1 ? "1 copy" : "\(bib.totalCopies) copies"
        let waiting = bib.heldCopies == 1 ? "1 hold" : "\(bib.heldCopies) holds"
        // Only what's there to say: no holds, just the copies; no copies yet, just the holds.
        if bib.heldCopies == 0 { return copies }
        if bib.totalCopies == 0 { return waiting }
        return "\(waiting) on \(copies)"
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

struct HoldStatusBadge: View {
    var hold: Hold

    var body: some View {
        let (text, color): (String, Color) = switch hold.status {
        case "READY_FOR_PICKUP": ("Ready for pickup" + (hold.pickupByDate.map { " by \(DateText.format($0))" } ?? ""), .green)
        case "IN_TRANSIT": ("In transit", .orange)
        case "SUSPENDED": ("Paused", .secondary)
        case "NOT_YET_AVAILABLE": ("Not yet available", .secondary)
        default: (hold.status.prettified, .secondary)
        }
        Text(text).foregroundStyle(color).fontWeight(hold.status == "READY_FOR_PICKUP" ? .semibold : .regular)
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
    private static let input: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ s: String) -> Date? { input.date(from: String(s.prefix(10))) }

    /// Days since 1970-01-01 of an ISO date, or 0.
    static func dayNumber(_ s: String) -> Int {
        let parts = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard parts.count == 3, let d = utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return 0 }
        return Int(d.timeIntervalSince1970 / 86400)
    }

    static func format(_ s: String) -> String {
        date(s)?.formatted(date: .abbreviated, time: .omitted) ?? s
    }

    static func isPast(_ s: String) -> Bool {
        guard let d = date(s) else { return false }
        return d < Calendar.current.startOfDay(for: .now)
    }
}
