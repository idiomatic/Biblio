import SwiftUI

/// What a library window shows: the set of the library's cards that are included. One card is an
/// ordinary account window; several are combined. Changing it keeps the window's section,
/// search, and selection.
struct CardScope {
    var library: LibraryInfo
    /// The cards in scope, in the library's order.
    var current: [String]
    /// Whether another window has this card.
    var isBusy: (String) -> Bool
    /// Includes or excludes a card; the window reopens on its sidebar.
    var set: (String, Bool) -> Void
    /// Places a hold for a card, from an item dropped on its row.
    var placeHold: (String, Bib) -> Void
    var add: () -> Void

    func style(_ user: String) -> CardStyle {
        CardStyle.of(library: library, username: user, name: name(user))
    }

    func name(_ user: String) -> String {
        LibraryStore.shared.cards[CardInfo.id(subdomain: library.subdomain, username: user)]?.name ?? user
    }
}

/// The sidebar's Cards section, in stock sidebar rows so everything lines up: each card opens its
/// account page, and a switch includes it in the lists (with one card there is no switch).
struct CardsSection: View {
    var scope: CardScope

    /// The card whose row an item is being dragged over.
    @State private var dropTarget: String?

    private var several: Bool { scope.library.users.count >= 2 }

    var body: some View {
        Section("Cards") {
            ForEach(scope.library.users, id: \.self) { user in row(user) }
            Button(action: scope.add) { Label("Add Card…", systemImage: "plus.circle") }
                .buttonStyle(.plain)
        }
    }

    private func row(_ user: String) -> some View {
        let on = scope.current.contains(user)
        let busy = scope.isBusy(user) && !on
        // Only the icon and name dim for a card that is out of the window; its row still opens
        // the card's page, to sign out or see the card.
        let dim = on ? 1.0 : 0.55
        let link = NavigationLink(value: AppSection.account(user)) {
            Label {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(scope.name(user)).lineLimit(1).opacity(dim)
                    if busy { Text("Open in another window").font(.caption).foregroundStyle(.secondary) }
                }
                if several {
                    Spacer(minLength: 0)
                    Toggle("Include \(scope.name(user))", isOn: Binding(get: { on }, set: { scope.set(user, $0) }))
                        .labelsHidden()
                        .disabled(busy || (on && scope.current.count == 1))
                        .help(busy ? "\(scope.name(user)) is open in another window." : "Include in the lists")
                }
            }
        } icon: {
            CardChip(style: scope.style(user), size: 22).opacity(dim)
        }
        }
        // Dropping an item on a card's row places a hold for that card.
        return link
            .onDrop(of: on ? [.biblioItem] : [], isTargeted: Binding(get: { dropTarget == user },
                                                                    set: { dropTarget = $0 ? user : (dropTarget == user ? nil : dropTarget) })) { providers in
                BibTransfer.load(from: providers) { item in
                    if item.subdomain == scope.library.subdomain { scope.placeHold(user, item.bib) }
                }
            }
            .listRowBackground(dropTarget == user ? Color.accentColor.opacity(0.25) : nil)
    }
}

/// The page of a card that is out of the window: no session, so no settings to edit, but its
/// barcode and Sign Out (which removes it from the device); the sidebar's switch brings it back.
struct InactiveCardView: View {
    var scope: CardScope
    var user: String
    var removeCard: (String) -> Void

    @State private var confirmSignOut = false

    private var busy: Bool { scope.isBusy(user) }
    private var barcode: String? {
        LibraryStore.shared.cards[CardInfo.id(subdomain: scope.library.subdomain, username: user)]?.barcode
    }

    var body: some View {
        Form {
            Section("Profile") {
                LabeledContent("Name", value: scope.name(user))
                LabeledContent("Library", value: scope.library.name)
            }
            if let barcode {
                Section {
                    BarcodeWithPicker(value: barcode, subdomain: scope.library.subdomain)
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                } header: {
                    Text("Library Card")
                }
            }
            CardAppearanceSection(library: scope.library, username: user, name: scope.name(user))
            Section {
                Button("Sign Out", role: .destructive) { confirmSignOut = true }
                    .disabled(busy)
                    .confirmationDialog("Sign out \(scope.name(user))?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                        Button("Sign Out", role: .destructive) { removeCard(user) }
                    }
            } footer: {
                Text(busy ? "This card is in use in another window. Close it there to sign it out."
                          : "This card is switched off. Turn it on in the sidebar to see its holds, loans, and history and to change its settings. Signing out removes it and its saved password from this device.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Account")
    }
}

/// Edits a card's monogram and color; the one place it's done, on the card's page.
struct CardAppearanceSection: View {
    var library: LibraryInfo
    var username: String
    /// The patron's name, which gives the default monogram.
    var name: String
    /// The first name in the library's contact record, if it gave one.
    var firstName: String? = nil

    /// What the card is called when nothing was chosen.
    private var defaultCallName: String {
        if let firstName, !firstName.isEmpty { return WindowSession.tidied(firstName) }
        return WindowSession.tidied(name.split(separator: " ").first.map(String.init) ?? name)
    }

    private var look: CardLook { LibraryStore.shared.look(subdomain: library.subdomain, username: username) }
    private var style: CardStyle { CardStyle.of(library: library, username: username, name: name) }
    private var defaultStyle: CardStyle {
        CardStyle(index: library.users.firstIndex(of: username) ?? 0, name: name)
    }

    var body: some View {
        Section {
            TextField("Name", text: Binding(
                get: { look.name ?? "" },
                set: { text in
                    var next = look
                    let limited = String(text.prefix(24))
                    next.name = limited.allSatisfy(\.isWhitespace) ? nil : limited
                    LibraryStore.shared.setLook(next, subdomain: library.subdomain, username: username)
                }), prompt: Text(defaultCallName))
                .autocorrectionDisabled()
            HStack(spacing: 12) {
                CardChip(style: style, size: 28)
                TextField("Monogram", text: Binding(
                    get: { look.monogram ?? defaultStyle.monogram },
                    set: { text in
                        // One or two letters, shown in capitals.
                        var next = look
                        let trimmed = String(text.filter { !$0.isWhitespace }.prefix(2)).uppercased()
                        next.monogram = trimmed.isEmpty || trimmed == defaultStyle.monogram ? nil : trimmed
                        LibraryStore.shared.setLook(next, subdomain: library.subdomain, username: username)
                    }))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
            }
            HStack(spacing: 10) {
                ForEach(CardStyle.palette.indices, id: \.self) { i in
                    let chosen = (look.color ?? (library.users.firstIndex(of: username) ?? 0) % CardStyle.palette.count) == i
                    Button {
                        var next = look
                        next.color = i
                        LibraryStore.shared.setLook(next, subdomain: library.subdomain, username: username)
                    } label: {
                        Circle()
                            .fill(CardStyle.palette[i])
                            .frame(width: 24, height: 24)
                            .overlay { if chosen { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) } }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Color \(i + 1)")
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            if !look.isDefault {
                Button("Reset to Default") {
                    LibraryStore.shared.setLook(CardLook(), subdomain: library.subdomain, username: username)
                }
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("When several cards show together, the name is used in “Hold for …” and the color and monogram mark this card’s items.")
        }
    }
}
