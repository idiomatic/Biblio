import SwiftUI

/// Subtle colors for availability and for this account's relationship to an item.
/// Colors only reinforce text and symbols, never replace them.
enum StatusColors {
    /// Title-level availability ("AVAILABLE", "UNAVAILABLE", "ON_ORDER", …).
    static func availability(_ status: String?) -> Color {
        switch status {
        case "AVAILABLE": .green
        case "UNAVAILABLE", "NOT_AVAILABLE": .orange
        case "ON_ORDER": .teal
        default: .secondary
        }
    }

    /// Copy-level status as the library words it ("In", "Out", "Held", "In-Process", "Missing", …).
    static func copy(_ copy: CopyAvailability) -> Color {
        if copy.isAvailable { return .green }
        let s = copy.status.lowercased()
        if ["missing", "lost", "damaged", "withdrawn", "claims"].contains(where: s.contains) { return .red }
        if ["transit", "transfer", "process", "order", "repair", "cataloging"].contains(where: s.contains) { return .teal }
        if s.contains("held") || s.contains("hold") { return .purple }
        return .orange
    }

    static func account(_ status: AccountStatus) -> Color {
        switch status {
        case .onHold(ready: true, _): .green
        case .onHold: .blue
        case .checkedOut(let due): due.map(DateText.isPast) == true ? .red : .purple
        }
    }
}

extension AccountStatus {
    var label: String {
        switch self {
        case .onHold(ready: true, _): "Ready for pickup"
        case .onHold(_, let position?): "On hold · #\(position)"
        case .onHold: "On hold"
        case .checkedOut(let due?): DateText.isPast(due) ? "Overdue" : "Checked out · due \(DateText.format(due))"
        case .checkedOut: "Checked out"
        }
    }

    var systemImage: String {
        switch self {
        case .onHold(ready: true, _): "bag.fill"
        case .onHold: "tray.and.arrow.down.fill"
        case .checkedOut: "book.fill"
        }
    }
}

/// Small capsule naming this account's status for an item in catalog lists and the detail pane.
struct AccountStatusTag: View {
    var status: AccountStatus

    var body: some View {
        let color = StatusColors.account(status)
        HStack(spacing: 4) {
            Image(systemName: status.systemImage)
                .imageScale(.small)
            Text(status.label)
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
