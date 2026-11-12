import SwiftUI

/// A card's page: its profile, barcode, and appearance, and the account settings (email,
/// password, default pickup location, language and borrowing history). A card switched off in
/// this window has no session here, so its page keeps every section in place with the settings
/// disabled, and toggling the card only changes what can be used.
struct AccountView: View {
    let library: LibraryInfo
    let username: String
    /// The card's session in this window; nil while the card is switched off.
    var session: WindowSession?
    var actions: WindowSession.WindowActions?
    /// Switched off because another window has the card.
    var isBusy = false

    init(session: WindowSession) {
        library = session.library
        username = session.username
        self.session = session
        actions = session.windowActions
        _restoring = State(initialValue: Self.scrollOffsets[CardInfo.id(subdomain: library.subdomain, username: username)])
    }

    /// The page of a card in a window: its session there, or nil while it's switched off.
    init(library: LibraryInfo, username: String, session: WindowSession?, actions: WindowSession.WindowActions?, isBusy: Bool) {
        self.library = library
        self.username = username
        self.session = session
        self.actions = actions
        self.isBusy = isBusy
        _restoring = State(initialValue: Self.scrollOffsets[CardInfo.id(subdomain: library.subdomain, username: username)])
    }

    @State private var email = ""
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var pickup: String?
    @State private var language: String?
    @State private var working: String?
    @State private var confirmHistoryOff = false
    @State private var confirmSignOut = false
    @State private var scroll = ScrollPosition()
    /// The saved place being scrolled back to as the page first lays out.
    @State private var restoring: CGFloat?
    @State private var restoreTries = 0

    var body: some View {
        Form {
            let patron = session?.patron
            // Switched off, or still signing in: the settings wait for the card's session.
            let off = patron == nil
            let on = session != nil
            // A switched-off card's profile and barcode dim, as its sidebar row does; the note doesn't.
            let dim = on ? 1.0 : 0.55
            Section {
                LabeledContent("Name", value: patron?.name ?? card?.name ?? username)
                    .opacity(dim)
                LabeledContent("Library", value: library.name)
                    .opacity(dim)
            } header: {
                VStack(alignment: .leading, spacing: 12) {
                    // Always laid out, and only shown for a switched-off card, so switching the card
                    // on or off moves nothing below it. It draws its own rectangle, hidden with it.
                    Label(isBusy ? "This card is open in another window. Close it there to change its settings or sign it out."
                                 : "This card is switched off. Switch it on in the sidebar to see its holds, loans, and history and to change its settings.",
                          systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .textCase(nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                        #if os(macOS)
                        // Headers sit further in than sections; reach the sections' edges.
                        .padding(.horizontal, -9)
                        #endif
                        .hidden(on)
                    Text("Profile")
                        .opacity(dim)
                }
            }

            Group {
                if let barcode = patron?.barcode ?? card?.barcode {
                    Section {
                        BarcodeWithPicker(value: barcode, subdomain: library.subdomain)
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                            .disabled(off)
                    } header: {
                        Text("Library Card")
                    } footer: {
                        Text("Show this at the library’s self-checkout or desk.")
                    }
                }
            }
            .opacity(dim)

            CardAppearanceSection(library: library, username: username, name: patron?.name ?? card?.name ?? username,
                                  firstName: patron?.firstName ?? card?.firstName)

            settings(patron)
                .disabled(off)

            if let actions {
                Section {
                    if LibraryStore.shared.libraries.count > 1 || LibraryStore.shared.isSoleLogin {
                        Button("Use a Different Library", action: actions.useDifferentLibrary)
                    }
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                        .disabled(isBusy)
                        .confirmationDialog("Sign out of \(library.shortName ?? library.name)?",
                                            isPresented: $confirmSignOut, titleVisibility: .visible) {
                            Button("Sign Out", role: .destructive) { actions.removeCard(username) }
                        }
                } footer: {
                    Text("Signing out removes this card and its saved password from this device.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Account")
        // Switching the card on or off rebuilds the page; it comes back where it was.
        .scrollPosition($scroll)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in
            // The first layouts report the top: keep asking for the saved place a few times before
            // recording anything, so they don't overwrite it.
            if let target = restoring, abs(y - target) > 1, restoreTries < 3 {
                restoreTries += 1
                scroll.scrollTo(y: target)
                return
            }
            restoring = nil
            Self.scrollOffsets[scrollKey] = y
        }
        .onAppear {
            resetFields()
            // Read when the page was made, before its first layout reports the top.
            if let restoring { scroll.scrollTo(y: restoring) }
        }
        .onChange(of: session?.patron) { resetFields() }
    }

    /// Where each card's page was scrolled to, for as long as the app runs.
    private static var scrollOffsets: [String: CGFloat] = [:]
    private var scrollKey: String { CardInfo.id(subdomain: library.subdomain, username: username) }

    private var card: CardInfo? { LibraryStore.shared.cards[CardInfo.id(subdomain: library.subdomain, username: username)] }

    /// The settings that need the card's session; empty and disabled while it's switched off.
    @ViewBuilder
    private func settings(_ patron: Patron?) -> some View {
        Section {
            TextField("Email address", text: $email)
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                #endif
            saveButton("Update Email", key: "email", disabled: email.isEmpty || email == patron?.email || !email.contains("@")) { session in
                try await session.client.changeEmail(email)
                return "Email address updated."
            }
        } header: {
            Text("Email")
        }

        Section {
            SecureField("Current password", text: $currentPassword)
                .textContentType(.password)
            SecureField("New password", text: $newPassword)
                .textContentType(.newPassword)
            SecureField("Confirm new password", text: $confirmPassword)
                .textContentType(.newPassword)
            if !confirmPassword.isEmpty && newPassword != confirmPassword {
                Text("Passwords don’t match.").font(.caption).foregroundStyle(.red)
            }
            saveButton("Change Password", key: "password",
                       disabled: currentPassword.isEmpty || newPassword.isEmpty || newPassword != confirmPassword) { session in
                try await session.client.changePassword(current: currentPassword, new: newPassword)
                currentPassword = ""; newPassword = ""; confirmPassword = ""
                return "Password changed. The new password is saved in the Keychain."
            }
        } header: {
            Text("Password")
        }

        Section {
            HStack {
                Picker("Pickup location", selection: savingOnChange($pickup, key: "pickup") { session, id in
                    try await session.client.setDefaultPickupLocation(id)
                    return "Default pickup location saved."
                }) {
                    if pickup == nil { Text("Not set").tag(String?.none) }
                    ForEach(session?.locations ?? []) { Text($0.name).tag(Optional($0.id)) }
                }
                if working == "pickup" { ProgressView().controlSize(.small) }
            }
        } header: {
            Text("Holds")
        } footer: {
            Text("Used for new holds unless you choose another location when placing one.")
        }

        Section {
            HStack {
                Picker("Language", selection: choosingSystemLanguage(savingOnChange($language, key: "language") { session, code in
                    try await session.client.changeLanguage(code)
                    session.searchList.reload()
                    session.newTitlesList.reload()
                    return "Library language changed to \(languageName(code))."
                })) {
                    if let system = systemLanguage, system != language {
                        Text("Use System Language").tag(Optional(Self.useSystemLanguage))
                        Divider()
                    }
                    ForEach(library.languages, id: \.self) { code in
                        Text(languageName(code)).tag(Optional(code))
                    }
                }
                if working == "language" { ProgressView().controlSize(.small) }
            }
        } header: {
            Text("Library Language")
        } footer: {
            Text("The language the library uses for your account. It’s separate from your device’s language.")
        }

        // The library may not say; a switched-off card shows the toggle off.
        if session == nil || patron?.borrowingHistoryEnabled != nil {
            let enabled = patron?.borrowingHistoryEnabled ?? false
            Section {
                HStack {
                    Toggle("Keep borrowing history", isOn: Binding(
                        get: { enabled },
                        set: { on in
                            if on { setHistory(true) } else { confirmHistoryOff = true }
                        }))
                    .disabled(working != nil)
                    .confirmationDialog("Turn off borrowing history?", isPresented: $confirmHistoryOff,
                                        titleVisibility: .visible) {
                        Button("Turn Off", role: .destructive) { setHistory(false) }
                        Button("Keep History", role: .cancel) {}
                    } message: {
                        Text("The library may permanently delete your existing borrowing history.")
                    }
                    if working == "history" { ProgressView().controlSize(.small) }
                }
                if enabled, let session {
                    BorrowedHistoryRow(index: session.borrowed) { session.borrowed.rebuild(client: session.client) }
                }
            } header: {
                Text("Borrowing History")
            } footer: {
                Text("When on, the library keeps a list of the items you check out, and Biblio marks what you’ve borrowed before. Refreshing fetches it all again.")
            }
        }
    }

    private func resetFields() {
        guard let p = session?.patron else { return }
        if email.isEmpty { email = p.email ?? "" }
        pickup = pickup ?? p.preferredPickup
        language = language ?? p.language
    }

    /// The picker's tag for "Use System Language".
    private static let useSystemLanguage = "system"

    /// The library's language closest to the system's preferred languages: the same
    /// language and region, else the same language.
    private var systemLanguage: String? {
        let codes = library.languages
        for preferred in Locale.preferredLanguages {
            if let exact = codes.first(where: { $0.caseInsensitiveCompare(preferred) == .orderedSame }) { return exact }
            let base = Locale(identifier: preferred).language.languageCode
            if let same = codes.first(where: { Locale(identifier: $0).language.languageCode == base }) { return same }
        }
        return nil
    }

    /// Turns choosing "Use System Language" into choosing the system's language.
    private func choosingSystemLanguage(_ value: Binding<String?>) -> Binding<String?> {
        Binding(get: { value.wrappedValue }, set: { new in
            value.wrappedValue = new == Self.useSystemLanguage ? systemLanguage : new
        })
    }

    private func languageName(_ code: String) -> String {
        let own = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        let local = Locale.current.localizedString(forIdentifier: code) ?? code
        return own == local ? own : "\(own) (\(local))"
    }

    private func setHistory(_ enabled: Bool) {
        guard let session else { return }
        working = "history"
        Task {
            do {
                try await session.client.setBorrowingHistory(enabled: enabled)
                session.show(enabled ? "Borrowing history turned on." : "Borrowing history turned off.")
                await session.refreshPatron()
                session.historyList.reload()
                if enabled { session.syncBorrowed() } else { session.borrowed.clear() }
            } catch {
                session.show(error.localizedDescription, isError: true)
            }
            working = nil
        }
    }

    /// A menu selection that saves as soon as it changes, and goes back to the previous
    /// value if saving fails.
    private func savingOnChange(_ value: Binding<String?>, key: String,
                                save: @escaping (WindowSession, String) async throws -> String) -> Binding<String?> {
        Binding(get: { value.wrappedValue }, set: { new in
            let old = value.wrappedValue
            guard let new, new != old, working == nil else { return }
            value.wrappedValue = new
            run(key) { session in
                do {
                    return try await save(session, new)
                } catch {
                    value.wrappedValue = old
                    throw error
                }
            }
        })
    }

    private func run(_ key: String, action: @escaping (WindowSession) async throws -> String) {
        guard let session else { return }
        working = key
        Task {
            do {
                session.show(try await action(session))
                await session.refreshPatron()
            } catch {
                session.show(error.localizedDescription, isError: true)
            }
            working = nil
        }
    }

    private func saveButton(_ title: String, key: String, disabled: Bool,
                            action: @escaping (WindowSession) async throws -> String) -> some View {
        HStack {
            Spacer()
            if working == key { ProgressView().controlSize(.small) }
            Button(title) { run(key, action: action) }
            .disabled(disabled || working != nil)
        }
    }
}

extension View {
    /// Hidden but still laid out when `hide` is true, so nothing around it moves.
    @ViewBuilder
    func hidden(_ hide: Bool) -> some View {
        if hide { hidden() } else { self }
    }
}
