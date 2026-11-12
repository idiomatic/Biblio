import SwiftUI

/// Inspector content when several list rows are selected: what's selected and what can be
/// done to all of them at once.
struct MultiSelectionView: View {
    @Bindable var session: WindowSession
    var entries: [ListEntry]
    /// In a combined window, holds choose their card.
    var cards: CombinedSession?

    @State private var working = false
    @State private var confirmCancel = false

    private var holdable: [ListEntry] { entries.holdable }

    private var cancelable: [Hold] { entries.cancelableHolds }
    private var uncancelable: Int { entries.uncancelableHoldCount }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("^[\(entries.count) Item](inflect: true) Selected")
                    .font(.title2.weight(.semibold))

                if let cards, !holdable.isEmpty {
                    PlaceHoldsView(combined: cards, bibs: holdable.map(\.bib))
                        .id(holdable.map(\.bib.id))
                }

                VStack(alignment: .leading, spacing: 8) {
                    if cards != nil {
                        // The sections above place holds.
                    } else if !holdable.isEmpty && !session.isGuest {
                        Button {
                            working = true
                            Task {
                                await session.placeHolds(holdable.map(\.bib))
                                working = false
                            }
                        } label: {
                            Label(holdable.count == 1 ? "Hold" : "Hold ^[\(holdable.count) Item](inflect: true)",
                                  systemImage: "tray.and.arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if !cancelable.isEmpty {
                        Button(role: .destructive) {
                            confirmCancel = true
                        } label: {
                            Label(cancelable.count == 1 ? "Cancel Hold" : "Cancel ^[\(cancelable.count) Hold](inflect: true)",
                                  systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                    if uncancelable > 0 {
                        Label(uncancelable == 1 ? "1 selected hold can’t be canceled online."
                                                 : "\(uncancelable) selected holds can’t be canceled online.",
                              systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if working { ProgressView().controlSize(.small) }
                    if session.isGuest {
                        Button("Sign In to Place Holds…", systemImage: "person.crop.circle") {
                            session.requestSignIn()
                        }
                        .buttonStyle(.bordered)
                    } else if holdable.isEmpty && cancelable.isEmpty {
                        Text("No actions apply to these items.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(working)

                Divider()

                ForEach((cards == nil || holdable.isEmpty ? entries : entries.filter { e in !holdable.contains { $0.id == e.id } }).prefix(50)) { entry in
                    HStack(spacing: 10) {
                        CoverImage(url: entry.bib.jacketSmall, format: entry.bib.format)
                            .frame(width: 30, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.bib.fullTitle).font(.callout).lineLimit(1)
                            Text(session.library.formatName(entry.bib.format))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if let status = entry.accountStatus {
                            Image(systemName: status.systemImage)
                                .foregroundStyle(StatusColors.account(status))
                                .accessibilityLabel(status.label)
                        }
                    }
                }
                if entries.count > 50 {
                    Text("and \(entries.count - 50) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(cancelable.count == 1 ? "Cancel this hold?" : "Cancel ^[\(cancelable.count) hold](inflect: true)?",
                            isPresented: $confirmCancel) {
            Button(cancelable.count == 1 ? "Cancel Hold" : "Cancel ^[\(cancelable.count) Hold](inflect: true)", role: .destructive) {
                working = true
                Task {
                    await session.cancel(cancelable)
                    working = false
                }
            }
            Button("Keep Holds", role: .cancel) {}
        }
    }
}

extension [ListEntry] {
    /// Catalog items the patron hasn't held or checked out, which can be held.
    var holdable: [ListEntry] {
        filter { $0.kind == .catalog && $0.bib.holdable && $0.accountStatus == nil }
    }

    var cancelableHolds: [Hold] {
        compactMap(\.hold).filter(\.canCancel)
    }

    /// Holds the library won't let the patron cancel (e.g. ready for pickup).
    var uncancelableHoldCount: Int {
        compactMap(\.hold).filter { !$0.canCancel }.count
    }
}
