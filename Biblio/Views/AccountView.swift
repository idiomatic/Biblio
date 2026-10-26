import SwiftUI

/// Account settings: email, password, default pickup location, language and borrowing history.
struct AccountView: View {
    @Bindable var session: WindowSession

    @State private var email = ""
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var pickup: String?
    @State private var language: String?
    @State private var working: String?
    @State private var confirmHistoryOff = false

    var body: some View {
        Form {
            if let patron = session.patron {
                Section("Profile") {
                    LabeledContent("Name", value: patron.name)
                    LabeledContent("Library", value: session.library.name)
                }

                if let barcode = patron.barcode {
                    Section {
                        CodabarView(value: barcode)
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    } header: {
                        Text("Library Card")
                    } footer: {
                        Text("Show this at the library’s self-checkout or desk.")
                    }
                }

                Section {
                    TextField("Email address", text: $email)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        #endif
                    saveButton("Update Email", key: "email", disabled: email.isEmpty || email == patron.email || !email.contains("@")) {
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
                               disabled: currentPassword.isEmpty || newPassword.isEmpty || newPassword != confirmPassword) {
                        try await session.client.changePassword(current: currentPassword, new: newPassword)
                        currentPassword = ""; newPassword = ""; confirmPassword = ""
                        return "Password changed. The new password is saved in the Keychain."
                    }
                } header: {
                    Text("Password")
                }

                Section {
                    HStack {
                        Picker("Pickup location", selection: savingOnChange($pickup, key: "pickup") { id in
                            try await session.client.setDefaultPickupLocation(id)
                            return "Default pickup location saved."
                        }) {
                            if pickup == nil { Text("Not set").tag(String?.none) }
                            ForEach(session.locations) { Text($0.name).tag(Optional($0.id)) }
                        }
                        if working == "pickup" { ProgressView().controlSize(.small) }
                    }
                } header: {
                    Text("Holds")
                } footer: {
                    Text("Used for new holds unless you choose another location when placing one.")
                }

                Section("Language") {
                    HStack {
                        Picker("Language", selection: savingOnChange($language, key: "language") { code in
                            try await session.client.changeLanguage(code)
                            session.searchList.reload()
                            session.newTitlesList.reload()
                            return "Language changed to \(languageName(code))."
                        }) {
                            ForEach(session.library.languages, id: \.self) { code in
                                Text(languageName(code)).tag(Optional(code))
                            }
                        }
                        if working == "language" { ProgressView().controlSize(.small) }
                    }
                }

                if let enabled = patron.borrowingHistoryEnabled {
                    Section {
                        HStack {
                            Toggle("Keep borrowing history", isOn: Binding(
                                get: { enabled },
                                set: { on in
                                    if on { setHistory(true) } else { confirmHistoryOff = true }
                                }))
                            .disabled(working != nil)
                            if working == "history" { ProgressView().controlSize(.small) }
                        }
                    } header: {
                        Text("Borrowing History")
                    } footer: {
                        Text("When on, the library keeps a list of the items you check out.")
                    }
                    .confirmationDialog("Turn off borrowing history?", isPresented: $confirmHistoryOff,
                                        titleVisibility: .visible) {
                        Button("Turn Off", role: .destructive) { setHistory(false) }
                        Button("Keep History", role: .cancel) {}
                    } message: {
                        Text("The library may permanently delete your existing borrowing history.")
                    }
                }
            } else {
                ProgressView("Signing in…")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Account")
        .onAppear(perform: resetFields)
        .onChange(of: session.patron) { resetFields() }
    }

    private func resetFields() {
        guard let p = session.patron else { return }
        if email.isEmpty { email = p.email ?? "" }
        pickup = pickup ?? p.preferredPickup
        language = language ?? p.language
    }

    private func languageName(_ code: String) -> String {
        let own = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        let local = Locale.current.localizedString(forIdentifier: code) ?? code
        return own == local ? own : "\(own) (\(local))"
    }

    private func setHistory(_ enabled: Bool) {
        working = "history"
        Task {
            do {
                try await session.client.setBorrowingHistory(enabled: enabled)
                session.show(enabled ? "Borrowing history turned on." : "Borrowing history turned off.")
                await session.refreshPatron()
                session.historyList.reload()
            } catch {
                session.show(error.localizedDescription, isError: true)
            }
            working = nil
        }
    }

    /// A menu selection that saves as soon as it changes, and goes back to the previous
    /// value if saving fails.
    private func savingOnChange(_ value: Binding<String?>, key: String,
                                save: @escaping (String) async throws -> String) -> Binding<String?> {
        Binding(get: { value.wrappedValue }, set: { new in
            let old = value.wrappedValue
            guard let new, new != old, working == nil else { return }
            value.wrappedValue = new
            run(key) {
                do {
                    return try await save(new)
                } catch {
                    value.wrappedValue = old
                    throw error
                }
            }
        })
    }

    private func run(_ key: String, action: @escaping () async throws -> String) {
        working = key
        Task {
            do {
                session.show(try await action())
                await session.refreshPatron()
            } catch {
                session.show(error.localizedDescription, isError: true)
            }
            working = nil
        }
    }

    private func saveButton(_ title: String, key: String, disabled: Bool,
                            action: @escaping () async throws -> String) -> some View {
        HStack {
            Spacer()
            if working == key { ProgressView().controlSize(.small) }
            Button(title) { run(key, action: action) }
            .disabled(disabled || working != nil)
        }
    }
}
