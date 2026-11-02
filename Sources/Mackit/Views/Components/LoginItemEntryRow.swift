import SwiftUI

/// One startup item inside an expanded group: what it is (kind icon,
/// launchd label or app name), where it lives (its plist or target
/// path), its switch, and a reveal action for the file behind it.
///
/// The switch is the row's only always-visible control; the reveal
/// button appears on hover, the same treatment the uninstall tool's
/// rows give their file button — a permanent button per row would make
/// the list read as a wall of controls.
struct LoginItemEntryRow: View {
    let item: LoginItem
    /// Whether this item's toggle is in flight.
    let isRunning: Bool
    let onToggle: (Bool) -> Void
    let onReveal: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind.symbolName)
                .font(.system(size: 15))
                .foregroundStyle(item.kind == .systemDaemon ? Color.accentColor : .secondary)
                .frame(width: 18)
                .help(L10n.tr(item.kind.labelKey))

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.label)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)

                // The plist's path for agents and daemons, the target's
                // for a legacy login item: where the thing actually
                // lives, which is what a user verifying a surprise entry
                // looks for.
                Text(verbatim: item.plistPath ?? item.targetPath ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 8)

            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }

            Button(action: onReveal) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovered ? 1 : 0)
            .help(L10n.tr("ctx.revealInFinder"))
            .disabled(item.plistPath == nil && item.targetPath == nil)

            Toggle(isOn: Binding(
                get: { item.isEnabled },
                set: { onToggle($0) }
            )) {
                EmptyView()
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(isRunning)
        }
        .padding(.leading, 60)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

private extension LoginItem.Kind {
    /// The row's leading symbol and its tooltip key.
    var symbolName: String {
        switch self {
        case .userAgent: return "person.circle"
        case .globalAgent: return "network"
        case .systemDaemon: return "lock.circle"
        case .legacyLoginItem: return "list.bullet.rectangle"
        }
    }

    var labelKey: String {
        switch self {
        case .userAgent: return "loginItems.kind.userAgent"
        case .globalAgent: return "loginItems.kind.globalAgent"
        case .systemDaemon: return "loginItems.kind.systemDaemon"
        case .legacyLoginItem: return "loginItems.kind.legacyLoginItem"
        }
    }
}
