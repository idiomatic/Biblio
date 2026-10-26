import SwiftUI

/// The front window's current list, refreshed by View > Refresh (⌘R).
struct RefreshAction {
    let perform: () -> Void
}

extension FocusedValues {
    @Entry var refreshList: RefreshAction?
}

struct RefreshCommands: Commands {
    @FocusedValue(\.refreshList) private var refresh

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            Button("Refresh") { refresh?.perform() }
                .keyboardShortcut("r")
                .disabled(refresh == nil)
            Divider()
        }
    }
}

struct MainView: View {
    @Bindable var session: WindowSession
    var signOut: () -> Void

    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @State private var holdsDropTargeted = false
    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    #endif

    var body: some View {
        content
            #if os(macOS)
            // The Settings window edits the account of whichever window was last in front.
            .onChange(of: controlActiveState, initial: true) { _, state in
                if state == .key { SessionRegistry.shared.activate(session) }
            }
            #endif
    }

    private var content: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            NavigationStack {
                detail
            }
        }
        .inspector(isPresented: $session.showInspector) {
            Group {
                if session.selectedEntries.count > 1 {
                    MultiSelectionView(session: session, entries: session.selectedEntries)
                } else if let bib = session.selection {
                    ItemDetailView(session: session, bib: bib)
                        .id(bib.id)
                } else {
                    ContentUnavailableView("No Selection", systemImage: "book.closed",
                                           description: Text("Select an item to see its details and availability."))
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
        }
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .principal) {
                SearchField(session: session)
                    .frame(width: 280)
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button {
                    session.showInspector.toggle()
                } label: {
                    Label("Item Details", systemImage: "sidebar.trailing")
                }
                .help("Show or hide item details")
            }
        }
        .overlay(alignment: .bottom) { BannerView(session: session) }
        .navigationTitle(session.library.shortName ?? session.library.name)
        #if os(macOS)
        .navigationSubtitle(session.displayName)
        #endif
        .task { await session.start() }
        .alert("Couldn’t Sign In", isPresented: .constant(session.loginError != nil && session.patron == nil)) {
            Button("Try Again") { Task { await session.start() } }
            Button("Choose Another User", role: .cancel) { signOut() }
        } message: {
            Text(session.loginError ?? "")
        }
    }

    private var sidebar: some View {
        List(selection: $session.section) {
            Section("Catalog") {
                sidebarRow(.search)
                sidebarRow(.newTitles)
            }
            if !session.isGuest {
            Section("My Library") {
                sidebarRow(.holds)
                    .onDrop(of: [.biblioItem], isTargeted: $holdsDropTargeted) { providers in
                        BibTransfer.load(from: providers) { item in Task { await session.placeHold(item) } }
                    }
                    .listRowBackground(holdsDropTargeted ? Color.accentColor.opacity(0.25) : nil)
                sidebarRow(.checkouts)
                sidebarRow(.history)
            }
            }
            Section(session.displayName) {
                #if os(iOS)
                // On macOS, account settings live in the Settings window (⌘,).
                if !session.isGuest { sidebarRow(.account) }
                #endif
                Button {
                    signOut()
                } label: {
                    if session.isGuest {
                        Label("Sign In", systemImage: "person.crop.circle.badge.plus")
                    } else {
                        Label("Switch User or Library", systemImage: "arrow.left.arrow.right")
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(session.library.shortName ?? "Library")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        #endif
    }

    private func sidebarRow(_ section: AppSection) -> some View {
        NavigationLink(value: section) {
            Label(section.title, systemImage: section.systemImage)
                .badge(badge(for: section))
        }
    }

    private func badge(for section: AppSection) -> Int {
        switch section {
        case .holds: session.holdsList.loaded ? session.holdsList.total : 0
        case .checkouts: session.checkoutsList.loaded ? session.checkoutsList.total : 0
        default: 0
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch session.section ?? .search {
        case .search: SearchView(session: session)
        case .newTitles: NewTitlesView(session: session)
        case .holds: BorrowingListView(session: session, section: .holds)
        case .checkouts: BorrowingListView(session: session, section: .checkouts)
        case .history: BorrowingListView(session: session, section: .history)
        case .account: AccountView(session: session)
        }
    }
}

/// Search field that also accepts dropped items (from any window) and searches for them.
struct SearchField: View {
    @Bindable var session: WindowSession
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search the catalog", text: $session.searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .onSubmit { session.runSearch(session.searchText) }
                #if os(iOS)
                .submitLabel(.search)
                #endif
            if !session.searchText.isEmpty {
                Button {
                    session.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(isTargeted ? 1 : 0.6), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: isTargeted ? 2 : 0)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let text = items.first?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return false }
            session.runSearch(text)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

struct BannerView: View {
    @Bindable var session: WindowSession

    var body: some View {
        if let banner = session.banner {
            Label(banner.message, systemImage: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .foregroundStyle(banner.isError ? Color.red : Color.primary)
                .shadow(radius: 6, y: 2)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: banner.id) {
                    try? await Task.sleep(for: .seconds(banner.isError ? 6 : 3))
                    withAnimation { session.banner = nil }
                }
                .onTapGesture { withAnimation { session.banner = nil } }
        }
    }
}
