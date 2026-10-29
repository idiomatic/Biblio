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
    /// Switches this guest window to a signed-in user.
    var signIn: (String) -> Void

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
            .onChange(of: ObjectIdentifier(session)) {
                if controlActiveState == .key { SessionRegistry.shared.activate(session) }
            }
            #endif
    }

    // A guest signing in swaps the session. On macOS the split view stays (replacing it leaves
    // the window's toolbar without its sidebar section), and only the detail and inspector,
    // which keep per-session state, start afresh.
    private var content: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            NavigationStack {
                detail
            }
            .id(ObjectIdentifier(session))
        }
        .modifier(ItemInspector(isPresented: $session.showInspector) { inspector.id(ObjectIdentifier(session)) })
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .principal) {
                SearchField(session: session)
                    .frame(width: 280)
            }
            #endif
            #if os(iOS)
            ToolbarItem(placement: .primaryAction) { InspectorToggle(session: session) }
            #endif
        }
        .overlay(alignment: .bottom) { BannerView(session: session) }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar(status: session.client.status) }
        .navigationTitle(session.library.shortName ?? session.library.name)
        #if os(macOS)
        .navigationSubtitle(session.displayName)
        #endif
        .task(id: ObjectIdentifier(session)) { await session.start() }
        .sheet(isPresented: $session.showingSignIn, onDismiss: session.signInDismissed) {
            LoginPicker(library: session.library, signIn: signIn)
        }
        .alert("Couldn’t Sign In", isPresented: .constant(session.loginError != nil && session.patron == nil)) {
            Button("Try Again") { Task { await session.start() } }
            Button("Choose Another User", role: .cancel) { signOut() }
        } message: {
            Text(session.loginError ?? "")
        }
    }

    private var inspector: some View {
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
            // Account settings live in the Settings window (⌘,) on macOS, and a guest signs in
            // from the toolbar.
            #if os(iOS)
            if !session.isGuest {
                Section {
                    NavigationLink(value: AppSection.account) {
                        Label(session.displayName, systemImage: AppSection.account.systemImage)
                    }
                    .accessibilityHint(AppSection.account.title)
                    Button(action: signOut) {
                        Label("Switch User or Library", systemImage: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.plain)
                }
            }
            #endif
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { VersionLabel() }
        .navigationTitle(session.library.shortName ?? "Library")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        .toolbar {
            ToolbarItem {
                if session.isGuest {
                    Button(action: session.requestSignIn) {
                        Label("Sign In", systemImage: "person.crop.circle")
                    }
                    .help("Sign in to place holds and see your account")
                } else {
                    LibraryCardButton(session: session)
                }
            }
        }
        #else
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if session.isGuest {
                    // Back to the library and user menu, to pick a user or another library.
                    Button("Sign In", systemImage: "person.crop.circle", action: signOut)
                } else {
                    LibraryCardButton(session: session)
                }
            }
        }
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

/// Item details: an inspector beside the window's content, or a sheet at compact width.
private struct ItemInspector<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder var panel: Panel
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        // An inspector is a sheet on iPhone anyway, and as one it leaves a window restored at
        // launch with its sidebar under the navigation bar.
        if sizeClass == .compact {
            content.sheet(isPresented: $isPresented) { panel }
        } else {
            content.inspector(isPresented: $isPresented) { panel }
        }
        #else
        content.inspector(isPresented: $isPresented) { panel }
        #endif
    }
}

/// Shows or hides the item details. On macOS each list adds it to its own toolbar, because
/// SwiftUI orders a window's toolbar items outermost view first and this button belongs last.
struct InspectorToggle: View {
    @Bindable var session: WindowSession

    var body: some View {
        Button {
            session.showInspector.toggle()
        } label: {
            Label("Item Details", systemImage: "sidebar.trailing")
        }
        .help("Show or hide item details")
    }
}

/// The app's version, subtly at the foot of the sidebar; it opens the About box.
private struct VersionLabel: View {
    @State private var showingAbout = false

    var body: some View {
        Button {
            #if os(macOS)
            About.showPanel()
            #else
            showingAbout = true
            #endif
        } label: {
            Text("Biblio \(About.version)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About Biblio, version \(About.version)")
        .sheet(isPresented: $showingAbout) { AboutView() }
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

/// The window's latest request to the library: `TITLE [SIZE]` (the URL on hover), with a spinner
/// while fetching. It fades out after a quiet spell.
struct StatusBar: View {
    var status: FetchStatus
    @State private var isShown = false
    static let fadeDelay: Duration = .seconds(2)

    var body: some View {
        HStack(spacing: 6) {
            if let fetch = status.last {
                let kib = (Double(fetch.bytes) / 1024).formatted(.number.precision(.fractionLength(1)))
                Text("\(fetch.title) [\(kib) KiB]")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(fetch.url.absoluteString)
            }
            Spacer(minLength: 0)
            if status.active > 0 {
                ProgressView().controlSize(.mini)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(minHeight: 16)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .opacity(isShown ? 1 : 0)
        .task(id: status.activity) {
            guard status.activity > 0 else { return }
            withAnimation(.easeIn(duration: 0.15)) { isShown = true }
            guard status.active == 0 else { return }
            try? await Task.sleep(for: Self.fadeDelay)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.6)) { isShown = false }
        }
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
