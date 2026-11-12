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

    /// What the card is called: its Appearance name, else the account holder's first name.
    func name(_ user: String) -> String {
        LibraryStore.shared.callName(subdomain: library.subdomain, username: user)
    }
}

/// The sidebar's Cards section, in stock sidebar rows so everything lines up: each card opens its
/// account page, and a toggle includes it in the lists (with one card there is none): on macOS a
/// checkbox before the card's chip, as in Safari's Extensions; elsewhere a switch at the row's end.
/// Standard controls, so they follow the system's look as it changes.
struct CardsSection: View {
    var scope: CardScope

    /// The card whose row an item is being dragged over.
    @State private var dropTarget: String?

    private var several: Bool { scope.library.users.count >= 2 }

    /// The checkbox comes before the icon on macOS.
    private var leadingToggle: Bool {
        #if os(macOS)
        several
        #else
        false
        #endif
    }

    var body: some View {
        Section("Cards", isExpanded: LibraryStore.shared.sidebarSection("Cards", in: scope.library.subdomain)) {
            ForEach(scope.library.users, id: \.self) { user in row(user) }
            Button(action: scope.add) {
                HStack(spacing: 6) {
                    // Keeps the icon in line with the cards' chips, past their checkboxes.
                    if leadingToggle { Toggle("", isOn: .constant(false)).labelsHidden().hidden() }
                    Label("Add Card…", systemImage: "plus.circle")
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func toggle(_ user: String, on: Bool, busy: Bool) -> some View {
        Toggle("Include \(scope.name(user))", isOn: Binding(get: { on }, set: { scope.set(user, $0) }))
            .labelsHidden()
            .disabled(busy || (on && scope.current.count == 1))
            .help(busy ? "\(scope.name(user)) is open in another window." : "Include in the lists")
    }

    private func row(_ user: String) -> some View {
        let on = scope.current.contains(user)
        let busy = scope.isBusy(user) && !on
        // Only the icon and name dim for a card that is out of the window; its row still opens
        // the card's page, to sign out or see the card.
        let dim = on ? 1.0 : 0.55
        let link = NavigationLink(value: AppSection.account(user)) {
            HStack(spacing: 6) {
            // Before the label, not in its icon slot, which is only an icon wide.
            if leadingToggle { toggle(user, on: on, busy: busy) }
            Label {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(scope.name(user)).lineLimit(1).opacity(dim)
                        if busy { Text("Open in another window").font(.caption).foregroundStyle(.secondary) }
                    }
                    if several && !leadingToggle {
                        Spacer(minLength: 0)
                        toggle(user, on: on, busy: busy)
                    }
                }
            } icon: {
                CardChip(style: scope.style(user), size: 22).opacity(dim)
            }
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
        if let firstName, !firstName.isEmpty { return LibraryStore.tidied(firstName) }
        return LibraryStore.tidied(name.split(separator: " ").first.map(String.init) ?? name)
    }

    /// What the card is called now, chosen or not; the chip takes its initial.
    private var callName: String {
        LibraryStore.shared.callName(subdomain: library.subdomain, username: username, firstName: firstName, name: name)
    }

    private var look: CardLook { LibraryStore.shared.look(subdomain: library.subdomain, username: username) }
    private var style: CardStyle { CardStyle.of(library: library, username: username, name: callName) }
    private var defaultStyle: CardStyle {
        CardStyle(index: library.users.firstIndex(of: username) ?? 0, name: callName)
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
