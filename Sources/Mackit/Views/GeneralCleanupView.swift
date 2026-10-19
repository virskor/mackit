import SwiftUI

/// The general cleanup module: a Lemon-style page for everyone who is not a
/// developer — browser caches, useless language files, system junk, Downloads
/// and the Trash.
///
/// Deliberately a separate page rather than more rows in the developer list:
/// the two audiences share nothing, and mixing them makes each wade through
/// categories that mean nothing to them. The layout follows Lemon's: one big
/// "cleanable files" number with the scan and clean actions beside it, then
/// groups of rule rows, each row showing its total and a safety level (very
/// clean / recommended / caution). Rows arrive pre-checked up to
/// "recommended"; caution rows stay unchecked until the user opts in, and
/// cleaning still goes through the confirmation sheet.
struct GeneralCleanupView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        VStack(spacing: 0) {
            // The header stays outside the scroll area: the number and both
            // actions remain reachable however long the row list gets.
            header

            if vm.phase == .idle && vm.items.isEmpty {
                startPrompt
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(vm.generalCleanGroups) { group in
                            groupSection(group)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            IconBadge(
                systemImage: "sparkles",
                tint: .orange,
                diameter: 46,
                symbolSize: 22,
                cornerRadius: 12,
                fillOpacity: 0.14
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: L10n.tr("general.header.title"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                if vm.phase == .scanning {
                    Text(verbatim: L10n.tr("scan.progress.title"))
                        .font(.system(size: 24, weight: .bold))
                    ProgressView(value: vm.progressFraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 220)
                    Text(verbatim: vm.progressLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if vm.items.isEmpty {
                    Text(verbatim: L10n.tr("general.header.none"))
                        .font(.system(size: 24, weight: .bold))
                } else {
                    Text(verbatim: Formatters.bytes(vm.generalTotalSize))
                        .font(.system(size: 26, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                rescanButton
                if !vm.scopeSelectedItems.isEmpty {
                    cleanButton
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 14)
    }

    private var rescanButton: some View {
        Button {
            if vm.phase == .scanning {
                vm.cancelScan()
            } else {
                vm.startScan()
            }
        } label: {
            Label(
                vm.phase == .scanning
                    ? L10n.tr("toolbar.stopScan")
                    : L10n.tr("toolbar.rescan"),
                systemImage: vm.phase == .scanning ? "stop.circle" : "arrow.clockwise"
            )
        }
        .controlSize(.small)
    }

    /// The page's primary action: cleans the current selection (the rows the
    /// user left checked), through the same confirmation sheet as the
    /// developer list.
    private var cleanButton: some View {
        Button {
            vm.requestClean()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                Text(verbatim: L10n.fmt("clean.buttonWithSize", Formatters.bytes(vm.scopeSelectedSize)))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 12)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(vm.isBusy)
        .help(L10n.fmt("clean.helpSelected.other", vm.scopeSelectedItems.count))
    }

    /// Shown before the first scan: the whole page is one call to action.
    private var startPrompt: some View {
        VStack(spacing: 12) {
            Text(verbatim: L10n.tr("welcome.title"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button {
                vm.startScan()
            } label: {
                Text(verbatim: L10n.tr("general.header.start"))
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Groups

    private func groupSection(_ group: AppViewModel.GeneralRuleGroupState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: group.group.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(group.group.tint)

                Text(verbatim: group.group.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(group.group.tint)

                Spacer(minLength: 8)

                Text(verbatim: L10n.fmt(
                    "general.group.summary",
                    Formatters.bytes(group.totalSize),
                    Formatters.bytes(group.selectedSize)
                ))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            VStack(spacing: 0) {
                ForEach(Array(group.rows.enumerated()), id: \.element.row.id) { index, rowState in
                    if index > 0 {
                        Divider().padding(.leading, 38)
                    }
                    ruleRow(rowState)
                }
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.bottom, 18)
        }
    }

    private func ruleRow(_ rowState: AppViewModel.GeneralRuleRowState) -> some View {
        Button {
            vm.setRowSelected(rowState.row, selected: !rowState.isFullySelected)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: rowState.isFullySelected
                    ? "checkmark.circle.fill"
                    : (rowState.isPartiallySelected ? "minus.circle.fill" : "circle"))
                    .font(.system(size: 15))
                    .foregroundStyle(rowState.isFullySelected || rowState.isPartiallySelected ? .green : .secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: rowState.row.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(verbatim: rowState.row.note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                trailing(rowState)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The row's right side, one baseline like Lemon's: the total in primary
    /// color, the safety level tinted after it. Rows with nothing found show
    /// the level alone.
    @ViewBuilder
    private func trailing(_ rowState: AppViewModel.GeneralRuleRowState) -> some View {
        let tint = levelTint(rowState.row.risk)

        if rowState.items.isEmpty {
            Text(verbatim: L10n.tr(levelKey(rowState.row.risk)))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
        } else {
            HStack(spacing: 3) {
                Text(verbatim: L10n.fmt("general.row.total", Formatters.bytes(rowState.size)))
                    .font(.system(size: 12))
                    .monospacedDigit()
                Text(verbatim: L10n.tr("general.row.separator"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(verbatim: L10n.tr(levelKey(rowState.row.risk)))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint)
            }
        }
    }

    private func levelKey(_ risk: RiskLevel) -> String {
        switch risk {
        case .safe: return "general.badge.veryClean"
        case .review: return "general.badge.recommended"
        case .caution: return "general.badge.caution"
        }
    }

    private func levelTint(_ risk: RiskLevel) -> Color {
        switch risk {
        case .safe: return .green
        case .review: return .orange
        case .caution: return .red
        }
    }
}
