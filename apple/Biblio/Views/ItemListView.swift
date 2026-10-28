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
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    /// Owned here (not by the system Edit button) so window updates can't reset it mid-selection.
    @State private var editMode: EditMode = .inactive
    #endif

    var body: some View {
        Group {
            // Guests can't act on several items at once, so their lists select one at a time.
            if session.isGuest {
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
        .refreshable { await model.refresh() }
        .focusedSceneValue(\.refreshList, RefreshAction { Task { await model.refresh() } })
        .contextMenu(forSelectionType: ListEntry.ID.self) { ids in
            menu(for: entries(ids))
        }
        .onChange(of: selection) { _, ids in
            session.select(entries: entries(ids))
        }
        .task { model.loadIfNeeded() }
        // A list left open while the app was in the background may have gone stale.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.loadIfNeeded() }
        }
        .toolbar {
            ListControls(model: model, library: session.library)
            #if os(macOS)
            if session.isGuest {
                ToolbarItem {
                    Button(action: session.requestSignIn) {
                        Label("Sign In", systemImage: "person.crop.circle")
                    }
                    .help("Sign in to place holds and see your account")
                }
            }
            ToolbarItem { InspectorToggle(session: session) }
            #endif
            #if os(iOS)
            // Multiple selection on iOS/iPadOS happens in edit mode (or with a two-finger drag).
            if !session.isGuest {
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
            #endif
        }
        .confirmationDialog(confirmCancel.count == 1 ? "Cancel this hold?" : "Cancel \(confirmCancel.count) holds?",
                            isPresented: .constant(!confirmCancel.isEmpty), presenting: confirmCancel) { holds in
            Button(holds.count == 1 ? "Cancel Hold" : "Cancel \(holds.count) Holds", role: .destructive) {
                Task { await session.cancel(holds) }
                selection.subtract(holds.map { "hold-\($0.id)" })
                confirmCancel = []
            }
            Button(confirmCancel.count == 1 ? "Keep Hold" : "Keep Holds", role: .cancel) { confirmCancel = [] }
        }
    }

    @ViewBuilder
    private var rows: some View {
        header()
        ForEach(model.rows) { row in
            switch row {
            case .item(let entry):
                ItemRow(entry: entry, library: session.library)
                    .tag(entry.id)
                    // Tint by this account's status; selected rows keep the system highlight.
                    .listRowBackground(selection.contains(entry.id) ? nil
                                       : entry.accountStatus.map { StatusColors.account($0).opacity(0.08) })
                    .onAppear { model.itemAppeared(entry) }
                    #if os(iOS)
                    .swipeActions {
                        if case .hold(let h) = entry.kind, h.canCancel {
                            Button("Cancel Hold", systemImage: "xmark", role: .destructive) { confirmCancel = [h] }
                        }
                    }
                    #endif
            case .placeholder(let position):
                PlaceholderRow()
                    .selectionDisabled()
                    .onAppear { model.placeholderAppeared(position) }
                    .onDisappear { model.placeholderDisappeared(position) }
            }
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
        let cancellable = selected.compactMap(\.hold).filter(\.canCancel)
        if selected.count == 1, let entry = selected.first {
            Button("Show Details", systemImage: "info.circle") { session.select(entry.bib) }
        }
        if !holdable.isEmpty && !session.isGuest {
            Button(holdable.count == 1 ? "Hold" : "Hold \(holdable.count) Items", systemImage: "tray.and.arrow.down") {
                Task { await session.placeHolds(holdable.map(\.bib)) }
            }
        }
        if !cancellable.isEmpty {
            Button(cancellable.count == 1 ? "Cancel Hold…" : "Cancel \(cancellable.count) Holds…",
                   systemImage: "xmark.circle", role: .destructive) { confirmCancel = cancellable }
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
                HStack(spacing: 6) {
                    Text(library.formatName(bib.format))
                    if let year = bib.displayDate { Text("· \(year)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                status
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var status: some View {
        switch entry.kind {
        case .catalog:
            AvailabilityBadge(bib: bib)
            if let status = entry.catalogStatus { AccountStatusTag(status: status) }
        case .hold(let h):
            HStack(spacing: 6) {
                HoldStatusBadge(hold: h)
                    .fixedSize()
                OnOrderNote(bib: bib)
                if let p = h.position { Text("#\(p) in line").foregroundStyle(.secondary) }
                if let loc = h.pickupLocation { Text("· \(loc)").foregroundStyle(.secondary).lineLimit(1) }
            }
            .font(.caption)
        case .checkout(let c):
            if let due = c.dueDate {
                Label("Due \(DateText.format(due))", systemImage: "calendar")
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
        HStack(spacing: 6) {
            switch bib.status {
            case "AVAILABLE":
                Label("Available", systemImage: "checkmark.circle.fill").foregroundStyle(StatusColors.availability(bib.status)).fixedSize()
            case "ON_ORDER":
                Label("On order", systemImage: "shippingbox").foregroundStyle(StatusColors.availability(bib.status)).fixedSize()
            case "UNAVAILABLE", "NOT_AVAILABLE":
                Label("All copies in use", systemImage: "clock").foregroundStyle(StatusColors.availability(bib.status)).fixedSize()
            case .some(let s):
                Text(s.prettified).foregroundStyle(.secondary)
            case nil:
                EmptyView()
            }
            if bib.status != "ON_ORDER" { OnOrderNote(bib: bib) }
            if bib.heldCopies > 0 || bib.totalCopies > 0 {
                Text(peopleWaiting).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
    }

    private var peopleWaiting: String {
        let copies = bib.totalCopies == 1 ? "1 copy" : "\(bib.totalCopies) copies"
        let waiting = bib.heldCopies == 1 ? "1 hold" : "\(bib.heldCopies) holds"
        return "· \(waiting) on \(copies)"
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

    static func format(_ s: String) -> String {
        date(s)?.formatted(date: .abbreviated, time: .omitted) ?? s
    }

    static func isPast(_ s: String) -> Bool {
        guard let d = date(s) else { return false }
        return d < Calendar.current.startOfDay(for: .now)
    }
}
