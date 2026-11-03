import SwiftUI
import AppKit

/// One app's startup-item group: the app's icon and name, how many
/// items it has, the aggregate status, a master switch over every item,
/// and the disclosure that expands the individual entries.
///
/// The row is a button (expand) with the switch as a sibling, never a
/// nested gesture: a tap on the switch must not also fire the expand —
/// the same three-sibling-buttons pattern the uninstall tool's rows use.
struct LoginItemGroupRow: View {
    let group: LoginItemGroup
    let isExpanded: Bool
    /// The app's real icon; nil falls back to a generic symbol.
    let icon: NSImage?
    /// Whether any item of this group is mid-toggle.
    let isRunning: Bool
    let onToggle: (Bool) -> Void
    let onExpand: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Expand: the whole row's content is the target, the switch
            // excluded.
            Button(action: onExpand) {
                HStack(spacing: 10) {
                    if let icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 24, height: 24)
                    } else {
                        CategoryIcon(category: .apps, size: 18, width: 24)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: group.name)
                            .font(Theme.Typography.bodyMedium)
                            .lineLimit(1)

                        Text(verbatim: L10n.items(group.items.count))
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                    }

                    StatusPill(status: group.status.pillStatus)

                    Image(systemName: "chevron.right")
                        .font(Theme.Typography.captionEmphasis)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // The master switch: every item of the group at once. On
            // when any item is on, so a partially-enabled group reads as
            // "on, but not all of it" — the status pill carries the
            // nuance — and one click takes the whole group the other
            // way.
            Toggle(isOn: Binding(
                get: { group.status != .allDisabled },
                set: { onToggle($0) }
            )) {
                EmptyView()
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(isRunning)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private extension LoginItemGroup.Status {
    /// Maps the scanner's group status onto the pill's.
    var pillStatus: StatusPill.Status {
        switch self {
        case .allEnabled: return .allEnabled
        case .partial: return .partial
        case .allDisabled: return .allDisabled
        }
    }
}
