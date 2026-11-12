import SwiftUI

/// New-window menu: choose a library, then a user of that library.
struct LauncherView: View {
    var preselectedLibrary: String?
    /// Shows the library list even with a single library, to add another.
    var listLibraries = false
    var open: (LibraryInfo, [String]) -> Void

    @State private var store = LibraryStore.shared
    @State private var addingLibrary = false
    @State private var pool = ClientPool.shared
    @State private var libraryToRemove: LibraryInfo?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.libraries) { library in
                        Button { choose(library) } label: {
                            HStack {
                                LibraryRow(library: library)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Browse as Guest", systemImage: "person.crop.circle.dashed") { open(library, []) }
                            Button(library.users.isEmpty ? "Remove Library" : "Remove Library…",
                                   systemImage: "trash", role: .destructive) {
                                requestRemoval(library)
                            }
                            .disabled(isInUse(library))
                        }
                    }
                    .onDelete { offsets in
                        if let i = offsets.first { requestRemoval(store.libraries[i]) }
                    }
                    .deleteDisabled(store.libraries.contains(where: isInUse))
                } header: {
                    Text("Libraries")
                } footer: {
                    if store.libraries.isEmpty {
                        Text("Add a BiblioCommons library to get started.")
                    }
                }
            }
            .navigationTitle("Choose a Library")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Library", systemImage: "plus") { addingLibrary = true }
                }
            }
            .overlay {
                if store.libraries.isEmpty {
                    ContentUnavailableView {
                        Label("No Libraries", systemImage: "building.columns")
                    } description: {
                        Text("Add your library by its BiblioCommons name, such as “wccls”.")
                    } actions: {
                        Button("Add Library") { addingLibrary = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .confirmRemoving($libraryToRemove, perform: remove)
            .sheet(isPresented: $addingLibrary) {
                AddLibraryView { info in
                    store.upsert(info)
                    open(info, [])
                }
            }
        }
        .macMinFrame(width: 360, height: 420)
        .task {
            if listLibraries { return }
            if let preselectedLibrary, let library = store.library(preselectedLibrary), store.libraries.count > 1 {
                choose(library)
            } else if store.libraries.count == 1, let only = store.libraries.first {
                choose(only)
            }
        }
    }

    /// Opens the library on the cards it last showed that no other window has (every free card
    /// if none of those is), or as a guest when there are none to offer (no saved cards, or
    /// every one open elsewhere); its Sign In adds or picks a card.
    private func choose(_ library: LibraryInfo) {
        let free = library.users.filter { !pool.isInUse(subdomain: library.subdomain, username: $0) }
        let remembered = (store.scopes[library.subdomain] ?? []).filter(free.contains)
        let users = remembered.isEmpty ? free : remembered
        open(library, users)
    }

    /// A library can't be removed while one of its logins is open in a window.
    private func isInUse(_ library: LibraryInfo) -> Bool {
        library.users.contains { pool.isInUse(subdomain: library.subdomain, username: $0) }
    }

    /// Confirms first only when removal would also delete saved users and passwords.
    private func requestRemoval(_ library: LibraryInfo) {
        if library.users.isEmpty { remove(library) } else { libraryToRemove = library }
    }

    private func remove(_ library: LibraryInfo) {
        guard !isInUse(library) else { return }
        for user in library.users + [""] {
            pool.discard(subdomain: library.subdomain, username: user)
        }
        store.remove(library.subdomain)
    }
}

struct LibraryRow: View {
    var library: LibraryInfo

    var body: some View {
        HStack(spacing: 12) {
            LibraryIconView(key: library.iconKey, website: library.websiteURL,
                            subdomain: library.subdomain, tint: library.tint)
            VStack(alignment: .leading) {
                Text(library.name)
                Text("\(library.subdomain).bibliocommons.com")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Sheet for signing a guest window in: the library's saved users, or a new one.
struct LoginPicker: View {
    var library: LibraryInfo
    var signIn: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var store = LibraryStore.shared
    @State private var pool = ClientPool.shared
    @State private var addingUser = false

    private var users: [String] { store.library(library.subdomain)?.users ?? [] }

    var body: some View {
        if users.isEmpty {
            AddUserView(library: library, onAdd: signIn)
        } else {
            NavigationStack {
                List {
                    Section {
                        ForEach(users, id: \.self) { user in
                            let inUse = pool.isInUse(subdomain: library.subdomain, username: user)
                            Button {
                                dismiss()
                                signIn(user)
                            } label: {
                                // The card as it appears elsewhere: its chip and name, then the login.
                                let name = store.callName(subdomain: library.subdomain, username: user)
                                HStack(spacing: 12) {
                                    CardChip(style: CardStyle.of(library: library, username: user, name: name), size: 28)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(name)
                                        if inUse {
                                            Text("Open in another window").font(.caption).foregroundStyle(.secondary)
                                        } else if name != user {
                                            Text(user).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .disabled(inUse)
                        }
                        Button {
                            addingUser = true
                        } label: {
                            Label("Add User…", systemImage: "person.badge.plus")
                        }
                    } footer: {
                        Text("Your search and selection stay as they are.")
                    }
                }
                .navigationTitle("Sign In to \(library.shortName ?? library.name)")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
                .sheet(isPresented: $addingUser) {
                    AddUserView(library: library) { user in
                        dismiss()
                        signIn(user)
                    }
                }
            }
            .macMinFrame(width: 360, height: 300)
        }
    }
}

struct AddLibraryView: View {
    var onAdd: (LibraryInfo) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var directory = LibraryDirectory.shared
    @State private var isWorking = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Library", text: $text, prompt: Text("wccls or https://wccls.bibliocommons.com"))
                        .focused($focused)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .onSubmit { Task { await add(LibraryLookup.subdomain(from: text)) } }
                } footer: {
                    Text("Enter the name before “.bibliocommons.com” in your library’s catalog address, or search by library name.")
                }

                let suggestions = directory.suggestions(for: text)
                if !suggestions.isEmpty {
                    Section("Suggestions") {
                        ForEach(suggestions) { entry in
                            Button {
                                Task { await add(entry) }
                            } label: {
                                HStack(spacing: 12) {
                                    LibraryIconView(key: entry.iconKey, website: entry.website, logo: entry.logo)
                                    VStack(alignment: .leading) {
                                        Text(entry.name)
                                        if let host = entry.website?.host() {
                                            Text(host).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                        }
                    }
                } else if directory.isLoading && text.count >= 2 {
                    Section { ProgressView("Loading library directory…") }
                }

                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .disabled(isWorking)
            .onAppear { focused = true }
            .navigationTitle("Add Library")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Add") { Task { await add(LibraryLookup.subdomain(from: text)) } }
                            .disabled(LibraryLookup.subdomain(from: text) == nil)
                    }
                }
            }
        }
        .macMinFrame(width: 420, height: 360)
        #if os(iOS)
        // Page sheet: a form sheet re-centers as the suggestions come and go, and as the keyboard
        // and the Passwords bar change, so it would hop while typing.
        .presentationSizing(.page)
        #endif
        .onAppear { directory.loadIfNeeded() }
    }

    private func add(_ entry: LibraryDirectory.Entry) async {
        isWorking = true
        error = nil
        if let sub = await LibraryDirectory.resolveSubdomain(for: entry) {
            await add(sub)
        } else {
            isWorking = false
            error = "Couldn’t find the catalog for \(entry.name). Enter its subdomain instead."
        }
    }

    private func add(_ subdomain: String?) async {
        guard let subdomain else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            let info = try await LibraryLookup.info(for: subdomain)
            onAdd(info)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct AddUserView: View {
    var library: LibraryInfo
    var onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var isScanning = false
    @FocusState private var focused: Field?

    private enum Field { case username, password }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Username or card number", text: $username)
                            .focused($focused, equals: .username)
                            .disabled(isWorking)
                            .textContentType(.username)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        #if os(iOS)
                        if canScanCard {
                            Button("Scan", systemImage: "barcode.viewfinder") { isScanning = true }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .disabled(isWorking)
                                .accessibilityLabel("Scan library card")
                        }
                        #endif
                    }
                    SecureField("PIN or password", text: $password)
                        .focused($focused, equals: .password)
                        .disabled(isWorking)
                        .textContentType(.password)
                        .onSubmit { Task { await signIn() } }
                } footer: {
                    Text("Your password is stored in the Keychain and used to sign in again automatically when the library ends your session.")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .onAppear { focused = .username }
            #if os(iOS)
            .sheet(isPresented: $isScanning) {
                CardScannerSheet { username = $0; focused = .password }
            }
            #endif
            .navigationTitle("Sign In to \(library.shortName ?? library.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Sign In") { Task { await signIn() } }
                            .disabled(username.isEmpty || password.isEmpty)
                    }
                }
            }
        }
        .macMinFrame(width: 400, height: 280)
        #if os(iOS)
        // An iPad form sheet re-centers above the keyboard and the Passwords bar, so it hops as
        // they change while typing; a page sheet stays put.
        .presentationSizing(.page)
        #endif
    }

    private func signIn() async {
        let user = username.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty, !password.isEmpty else { return }
        // Signing in again would end the session of the window already using this login.
        guard !ClientPool.shared.isInUse(subdomain: library.subdomain, username: user) else {
            error = "\(user) is already signed in in another window. Close that window first."
            return
        }
        isWorking = true
        error = nil
        defer { isWorking = false }
        let previous = Keychain.password(subdomain: library.subdomain, username: user)
        guard Keychain.setPassword(password, subdomain: library.subdomain, username: user) else {
            error = "The password couldn't be saved to the Keychain."
            return
        }
        let subdomain = library.subdomain
        let client = ClientPool.shared.client(subdomain: subdomain, username: user)
        func undoNumberLogin() {
            if let previous { Keychain.setPassword(previous, subdomain: subdomain, username: user) }
            else { Keychain.delete(subdomain: subdomain, username: user) }
            ClientPool.shared.discard(subdomain: subdomain, username: user)
        }
        do {
            let patron = try await client.login(force: true)
            var saved = user
            // A card number is saved under the username the library knows the patron by, when
            // that works too; one already saved under it keeps this fresher password.
            var rekey: (handle: String, previous: String?)?
            if user.allSatisfy(\.isNumber) {
                let handle = patron.name.trimmingCharacters(in: .whitespaces)
                let earlier = Keychain.password(subdomain: subdomain, username: handle)
                if !handle.isEmpty, handle.caseInsensitiveCompare(user) != .orderedSame, await verifyLogin(as: handle) {
                    rekey = (handle, earlier)
                    saved = handle
                }
            }
            // The same account saved under another login would show everything twice.
            if let card = CardInfo(library: library, username: saved, patron: patron),
               let other = LibraryStore.shared.cards.values.first(where: {
                   $0.subdomain == subdomain && $0.barcode == card.barcode && $0.username != saved
               }) {
                if let rekey { restoreLogin(rekey.handle, to: rekey.previous) }
                undoNumberLogin()
                self.error = "This card is already saved as “\(other.username)”."
                return
            }
            if rekey != nil {
                // The number login is replaced by the username one.
                Keychain.delete(subdomain: subdomain, username: user)
                LibraryStore.shared.removeUser(user, from: subdomain)
                ClientPool.shared.discard(subdomain: subdomain, username: user)
            }
            LibraryStore.shared.addUser(saved, password: password, to: subdomain)
            dismiss()
            onAdd(saved)
        } catch {
            undoNumberLogin()
            self.error = error.localizedDescription
        }
    }

    /// Signs in as `handle` with the password just typed, keeping it in the Keychain if that
    /// works; false if it doesn't, or another window has the login.
    private func verifyLogin(as handle: String) async -> Bool {
        let subdomain = library.subdomain
        guard !ClientPool.shared.isInUse(subdomain: subdomain, username: handle) else { return false }
        let previous = Keychain.password(subdomain: subdomain, username: handle)
        guard Keychain.setPassword(password, subdomain: subdomain, username: handle) else { return false }
        do {
            _ = try await ClientPool.shared.client(subdomain: subdomain, username: handle).login(force: true)
            return true
        } catch {
            restoreLogin(handle, to: previous)
            return false
        }
    }

    /// Puts a login's earlier saved password back, or forgets it if there was none.
    private func restoreLogin(_ handle: String, to previous: String?) {
        let subdomain = library.subdomain
        if let previous { Keychain.setPassword(previous, subdomain: subdomain, username: handle) }
        else { Keychain.delete(subdomain: subdomain, username: handle) }
        ClientPool.shared.discard(subdomain: subdomain, username: handle)
    }
}

extension View {
    /// Asks before removing `library` with saved users, since removal also deletes their passwords.
    /// Attached to each screen that offers removal, so the dialog appears over that screen.
    func confirmRemoving(_ library: Binding<LibraryInfo?>, perform: @escaping (LibraryInfo) -> Void) -> some View {
        confirmationDialog("Remove \(library.wrappedValue?.name ?? "Library")?",
                           isPresented: Binding(get: { library.wrappedValue != nil },
                                                set: { if !$0 { library.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: library.wrappedValue) { info in
            Button("Remove Library", role: .destructive) { perform(info) }
        } message: { info in
            Text("Its saved users and passwords will also be removed from this device.")
        }
    }
}
