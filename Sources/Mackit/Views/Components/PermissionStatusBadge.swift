import SwiftUI

/// The permission status capsule: symbol + label, tinted by state.
///
/// One badge per status vocabulary is the pattern here — `RiskBadge` for
/// risk levels, `OutdatedBadge` for outdated packages — so a status's
/// words, symbol and tint travel together instead of being reassembled at
/// each call site.
///
/// A refusal and a never-asked state share the warning tint: what differs
/// between them is the action under the row (jump to the pane versus ask
/// the system), and that belongs to the section, not the badge.
struct PermissionStatusBadge: View {
    let status: PermissionStatus

    var body: some View {
        Label(label, systemImage: symbol)
            .font(.system(size: 11, weight: .medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }

    private var label: String {
        switch status {
        case .granted: return L10n.tr("permissions.status.granted")
        // Both refusals read as "not granted" to the user; the action and
        // the hint under the row say which one this is.
        case .notGranted, .notRequested: return L10n.tr("permissions.status.notGranted")
        case .undetermined: return L10n.tr("permissions.status.undetermined")
        case .onDemand: return L10n.tr("permissions.status.onDemand")
        }
    }

    private var symbol: String {
        switch status {
        case .granted: return "checkmark.seal.fill"
        case .notGranted, .notRequested: return "exclamationmark.triangle.fill"
        case .undetermined: return "questionmark.circle"
        case .onDemand: return "clock"
        }
    }

    private var tint: Color {
        switch status {
        case .granted: return .green
        case .notGranted, .notRequested: return .orange
        case .undetermined: return Color.secondary
        case .onDemand: return .accentColor
        }
    }
}
