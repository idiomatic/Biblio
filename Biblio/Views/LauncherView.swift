import SwiftUI

/// New-window menu: choose a library, then a user of that library.
struct LauncherView: View {
    var preselectedLibrary: String?
    var open: (LibraryInfo, String) -> Void

    @State private var store = LibraryStore.shared
    @State private var path: [String] = []
    @State private var addingLibrary = false
    @State private var pool = ClientPool.shared
    @State private var libraryToRemove: LibraryInfo?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(store.libraries) { library in
                        NavigationLink(value: library.subdomain) {
                            LibraryRow(library: library)
                        }
                        .contextMenu {
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
            .navigationDestination(for: String.self) { subdomain in
                if let library = store.library(subdomain) {
                    UserPickerView(library: library, open: open,
                                   canRemove: !isInUse(library)) { remove(library) }
                }
            }
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
                    path = [info.subdomain]
                }
            }
        }
        .macMinFrame(width: 360, height: 420)
        .task {
            if path.isEmpty, let preselectedLibrary, store.library(preselectedLibrary) != nil, store.libraries.count > 1 {
                path = [preselectedLibrary]
            } else if path.isEmpty, store.libraries.count == 1, let only = store.libraries.first {
                path = [only.subdomain]
            }
        }
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
        path.removeAll { $0 == library.subdomain }
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

struct UserPickerView: View {
    var library: LibraryInfo
    var open: (LibraryInfo, String) -> Void
    var canRemove: Bool
    /// Removes the library; called once the user confirms.
    var remove: () -> Void

    @State private var store = LibraryStore.shared
    @State private var pool = ClientPool.shared
    @State private var addingUser = false
    @State private var libraryToRemove: LibraryInfo?

    private var users: [String] { store.library(library.subdomain)?.users ?? [] }

    var body: some View {
        List {
            Section {
                ForEach(users, id: \.self) { user in
                    let inUse = pool.isInUse(subdomain: library.subdomain, username: user)
                    Button {
                        open(store.library(library.subdomain) ?? library, user)
                    } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text(user)
                                if inUse {
                                    Text("Open in another window")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: inUse ? "person.crop.circle.badge.clock" : "person.crop.circle")
                        }
                    }
                    .disabled(inUse)
                    .help(inUse ? "This login is already open in another window. Each login can be used in one window at a time." : "")
                    .contextMenu {
                        Button("Remove User", systemImage: "trash", role: .destructive) {
                            store.removeUser(user, from: library.subdomain)
                            ClientPool.shared.discard(subdomain: library.subdomain, username: user)
                        }
                        .disabled(pool.isInUse(subdomain: library.subdomain, username: user))
                    }
                }
                .onDelete { offsets in
                    for i in offsets where !pool.isInUse(subdomain: library.subdomain, username: users[i]) {
                        store.removeUser(users[i], from: library.subdomain)
                    }
                }
                Button {
                    addingUser = true
                } label: {
                    Label("Add User…", systemImage: "person.badge.plus")
                }
            } header: {
                Text("Users")
            } footer: {
                if users.isEmpty { Text("Sign in with your library card number or username.") }
            }
            Section {
                Button {
                    open(store.library(library.subdomain) ?? library, "")
                } label: {
                    Label("Browse as Guest", systemImage: "person.crop.circle.dashed")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Guests can search and browse the catalog but can’t place holds or see an account.")
                    if !canRemove { Text("Close windows signed in to this library to remove it.") }
                }
            }
        }
        .navigationTitle(library.shortName ?? library.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(users.isEmpty ? "Remove Library" : "Remove Library…",
                       systemImage: "trash", role: .destructive) {
                    if users.isEmpty { remove() } else { libraryToRemove = store.library(library.subdomain) ?? library }
                }
                .confirmRemoving($libraryToRemove) { _ in remove() }
                .disabled(!canRemove)
                .help(canRemove ? "Remove this library and its saved users"
                                : "Close windows signed in to this library to remove it")
            }
        }
        .sheet(isPresented: $addingUser) {
            AddUserView(library: library) { user in
                open(store.library(library.subdomain) ?? library, user)
            }
        }
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
                                Label {
                                    VStack(alignment: .leading) {
                                        Text(user)
                                        if inUse {
                                            Text("Open in another window").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                } icon: {
                                    Image(systemName: inUse ? "person.crop.circle.badge.clock" : "person.crop.circle")
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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Library", text: $text, prompt: Text("wccls or https://wccls.bibliocommons.com"))
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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username or card number", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("PIN or password", text: $password)
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
            .disabled(isWorking)
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
        Keychain.setPassword(password, subdomain: library.subdomain, username: user)
        let client = ClientPool.shared.client(subdomain: library.subdomain, username: user)
        do {
            try await client.login(force: true)
            LibraryStore.shared.addUser(user, password: password, to: library.subdomain)
            dismiss()
            onAdd(user)
        } catch {
            if let previous { Keychain.setPassword(previous, subdomain: library.subdomain, username: user) }
            else { Keychain.delete(subdomain: library.subdomain, username: user) }
            ClientPool.shared.discard(subdomain: library.subdomain, username: user)
            self.error = error.localizedDescription
        }
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
