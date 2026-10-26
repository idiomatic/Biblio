import SwiftUI

/// Inspector content when several list rows are selected: what's selected and what can be
/// done to all of them at once.
struct MultiSelectionView: View {
    @Bindable var session: WindowSession
    var entries: [ListEntry]

    @State private var working = false
    @State private var confirmCancel = false

    private var holdable: [ListEntry] {
        entries.filter { $0.kind == .catalog && $0.bib.holdable && $0.accountStatus == nil }
    }

    private var cancellable: [Hold] {
        entries.compactMap(\.hold).filter(\.canCancel)
    }

    /// Selected holds the library won't let the patron cancel (e.g. ready for pickup).
    private var uncancellable: Int {
        entries.compactMap(\.hold).filter { !$0.canCancel }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(entries.count) Items Selected")
                    .font(.title2.weight(.semibold))

                VStack(alignment: .leading, spacing: 8) {
                    if !holdable.isEmpty && !session.isGuest {
                        Button {
                            working = true
                            Task {
                                await session.placeHolds(holdable.map(\.bib))
                                working = false
                            }
                        } label: {
                            Label(holdable.count == 1 ? "Hold" : "Hold \(holdable.count) Items",
                                  systemImage: "tray.and.arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if !cancellable.isEmpty {
                        Button(role: .destructive) {
                            confirmCancel = true
                        } label: {
                            Label(cancellable.count == 1 ? "Cancel Hold" : "Cancel \(cancellable.count) Holds",
                                  systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                    if uncancellable > 0 {
                        Label(uncancellable == 1 ? "1 selected hold can’t be cancelled online."
                                                 : "\(uncancellable) selected holds can’t be cancelled online.",
                              systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if working { ProgressView().controlSize(.small) }
                    if session.isGuest {
                        Label("Sign in to place holds.", systemImage: "person.crop.circle.badge.questionmark")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if holdable.isEmpty && cancellable.isEmpty {
                        Text("No actions apply to these items.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(working)

                Divider()

                ForEach(entries.prefix(50)) { entry in
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
        .confirmationDialog(cancellable.count == 1 ? "Cancel this hold?" : "Cancel \(cancellable.count) holds?",
                            isPresented: $confirmCancel) {
            Button(cancellable.count == 1 ? "Cancel Hold" : "Cancel \(cancellable.count) Holds", role: .destructive) {
                working = true
                Task {
                    await session.cancel(cancellable)
                    working = false
                }
            }
            Button("Keep Holds", role: .cancel) {}
        }
    }
}
