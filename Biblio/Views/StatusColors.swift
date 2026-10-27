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

    static func copy(_ copy: CopyAvailability) -> Color { copy.kind.color }

    static func account(_ status: AccountStatus) -> Color {
        switch status {
        case .onHold(ready: true, _): .green
        case .onHold: .blue
        case .checkedOut(let due): due.map(DateText.isPast) == true ? .red : .purple
        }
    }
}

/// A copy's status, grouped from the library's own wording ("In", "Out", "Held", "In-Process", …).
enum CopyKind {
    case available, onOrder, out, held, transit, repair, missing, withdrawn, claimsReturned, libraryUseOnly, other

    var systemImage: String {
        switch self {
        case .available: "checkmark.circle.fill"
        case .onOrder: "shippingbox"
        case .out: "clock"
        case .held: "bag"
        case .transit: "arrow.left.arrow.right"
        case .repair: "bandage"
        case .missing: "questionmark.circle"
        case .withdrawn: "xmark.circle"
        case .claimsReturned: "exclamationmark.circle"
        case .libraryUseOnly: "building.columns"
        case .other: "circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .available: .green
        case .onOrder: .teal
        case .out: .orange
        case .held: .purple
        case .transit: .indigo
        case .repair: .brown
        case .missing: .red
        case .withdrawn: .gray
        case .claimsReturned: .pink
        case .libraryUseOnly: .blue
        case .other: .orange
        }
    }
}

extension CopyAvailability {
    var kind: CopyKind {
        if isAvailable { return .available }
        if isOnOrder { return .onOrder }
        let s = status.lowercased()
        func has(_ words: String...) -> Bool { words.contains(where: s.contains) }
        // Order matters: "Claims Returned" before "returned", "Lost" before "out".
        if has("transit", "transfer") { return .transit }
        if has("process", "cataloging", "order") { return .onOrder }
        if has("repair", "damage", "mend", "bindery") { return .repair }
        if has("claim") { return .claimsReturned }
        if has("missing", "lost", "trace") { return .missing }
        if has("withdrawn", "discard") { return .withdrawn }
        if has("held", "hold") { return .held }
        if has("library use", "in library", "reference", "non-circ", "noncirc", "not for loan") { return .libraryUseOnly }
        if s == "out" || has("checked out", "due", "overdue") || dueDate != nil { return .out }
        return .other
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
