import SwiftUI

/// The general cleanup module: a Lemon-style page for everyone who is not a
/// developer — browser caches, app junk, useless language files, system junk,
/// Downloads and the Trash.
///
/// Deliberately a separate page rather than more rows in the developer list:
/// the two audiences share nothing, and mixing them makes each wade through
/// categories that mean nothing to them. The layout follows Lemon's: before
/// the first scan the whole page is one hero illustration and one call to
/// action; after it, one big "cleanable files" number with the scan and clean
/// actions beside it, then groups of rule rows, each row showing its total and
/// a safety level (very clean / recommended / caution). Rows arrive pre-checked
/// up to "recommended" except the ones that opted out — the unused language
/// files, whose removal changes every app's interface language at once — while
/// caution rows stay unchecked until the user opts in, and cleaning still goes
/// through the confirmation sheet. A row the scan found
/// nothing for stays interactive: its check is kept outside the item selection
/// (see `AppViewModel.handCheckedGeneralRows`), so the user can opt a row like
/// the Trash in before it has anything in it, and the remember prompt then
/// carries that choice into later scans. Rows whose entries group naturally
/// (language files, app junk) show one sub-row per language or per app, so a
/// single language — or a single app's caches — can be kept while the rest is
/// swept. The header carries the remember / restore shortcut for the row
/// selection, so a remembered selection is never a one-way door.
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
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: L10n.tr("general.header.title"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                if vm.phase == .scanning {
                    Text(verbatim: L10n.tr(vm.cleanupScope.scanProgressTitleKey))
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
                        .font(.system(size: 30, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                // The remember / restore shortcut for the row selection.
                // Adaptive rather than two permanent buttons: while a
                // selection is remembered the only sensible action is going
                // back to the default, and before that the only sensible one
                // is remembering. With the built-in default in effect and
                // nothing remembered, neither applies and the row stays empty.
                //
                // Hidden while scanning for the same reason the clean button
                // is: rows stream in and get pre-checked as the rules run, so
                // mid-scan the selection is a moving target — remembering it
                // would save whatever happened to have been found so far.
                if vm.phase != .scanning {
                    if vm.hasRememberedGeneralSelection {
                        BrandCTAButton(
                            title: L10n.tr("general.restoreDefault"),
                            systemImage: "arrow.uturn.backward",
                            style: .secondary,
                            compact: true
                        ) {
                            vm.restoreDefaultGeneralSelection()
                        }
                        .help(L10n.tr("general.restoreDefault.help"))
                    } else if vm.generalSelectionDiffersFromSaved() {
                        BrandCTAButton(
                            title: L10n.tr("general.remember.action"),
                            systemImage: "star",
                            style: .secondary,
                            compact: true
                        ) {
                            vm.rememberGeneralSelection()
                        }
                        .help(L10n.tr("general.remember.help"))
                    }
                }
                rescanButton
                // Hidden while scanning: rows stream in and get pre-checked as
                // the rules run, so a "Clean N kB" button would show a number
                // that keeps changing and can't be acted on yet. Showing it
                // disabled only produced a washed-out green blob.
                if !vm.scopeSelectedItems.isEmpty && vm.phase != .scanning {
                    BrandCTAButton(
                        title: L10n.fmt("clean.buttonWithSize", Formatters.bytes(vm.scopeSelectedSize)),
                        systemImage: "trash",
                        compact: true
                    ) {
                        vm.requestClean()
                    }
                    .disabled(vm.isBusy)
                    .help(L10n.fmt(
                        vm.scopeSelectedItems.count == 1
                            ? "clean.helpSelected.one"
                            : "clean.helpSelected.other",
                        vm.scopeSelectedItems.count
                    ))
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 14)
    }

    // Same metrics as the green "Clean" button beside it (see BrandCTAButton):
    // a system small control next to it renders visibly shorter, which makes
    // the header look misaligned. While scanning the label becomes "Stop" —
    // the user can always cancel a long scan.
    private var rescanButton: some View {
        BrandCTAButton(
            title: vm.phase == .scanning
                ? L10n.tr("toolbar.stopScan")
                : L10n.tr("toolbar.rescan"),
            systemImage: vm.phase == .scanning ? "stop.circle" : "arrow.clockwise",
            style: .secondary,
            compact: true
        ) {
            if vm.phase == .scanning {
                vm.cancelScan()
            } else {
                vm.startScan()
            }
        }
    }

    /// Shown before the first scan: the whole page is one call to action, the
    /// same hero composition as the developer module's welcome page — the
    /// screen a first-time user of this module sees should feel like the
    /// product's front door, not an empty state.
    private var startPrompt: some View {
        HeroPromptView(
            title: L10n.tr("general.hero.title"),
            message: L10n.tr("general.hero.message"),
            actionTitle: L10n.tr("general.header.start"),
            actionImage: "magnifyingglass"
        ) {
            vm.startScan()
        }
    }

    // MARK: - Groups

    private func groupSection(_ group: AppViewModel.GeneralRuleGroupState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // The header is the group-level toggle: one click checks or
            // unchecks every row in the group, with the same tri-state
            // checkbox the rows use. Without it, curating a whole group means
            // clicking each row, and "System Junk" has nine of them.
            Button {
                vm.setGroupSelected(group.group, selected: !group.isFullySelected)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: group.isFullySelected
                        ? "checkmark.circle.fill"
                        : (group.isPartiallySelected ? "minus.circle.fill" : "circle"))
                        .font(.system(size: 13))
                        .foregroundStyle(group.isFullySelected || group.isPartiallySelected ? .green : .secondary)
                        .frame(width: 18)
                        .symbolEffect(.bounce, value: group.isFullySelected)

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
                    .contentTransition(.numericText())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPressStyle())
            .help(L10n.tr("general.group.toggleHelp"))

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
        // A grouped row is one cell: the header toggles everything, and the
        // sub-rows below it toggle one language or one app at a time.
        VStack(spacing: 0) {
            rowHeader(rowState)

            if !rowState.subRows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(rowState.subRows.enumerated()), id: \.element.id) { index, sub in
                        if index > 0 {
                            Divider().padding(.leading, 40)
                        }
                        subRow(sub, of: rowState.row)
                    }
                }
                .padding(.leading, 22)
            }
        }
    }

    private func rowHeader(_ rowState: AppViewModel.GeneralRuleRowState) -> some View {
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
                    // The checkmark bounces as it is checked — a toggle with no
                    // motion makes the row feel like a label, not a control.
                    .symbolEffect(.bounce, value: rowState.isFullySelected)

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
        // RowPressStyle fully replaces the style (no .plain underneath): it
        // draws no chrome of its own, only the press fill.
        .buttonStyle(RowPressStyle())
    }

    /// One sub-row: a single language ("Tamil · 1.79 MB") or one app's junk.
    /// Same checkbox semantics as the row header, one level in.
    private func subRow(_ sub: AppViewModel.GeneralSubRowState, of row: GeneralRuleRow) -> some View {
        Button {
            vm.setSubRowSelected(row, key: sub.id, selected: !sub.isFullySelected)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: sub.isFullySelected
                    ? "checkmark.circle.fill"
                    : (sub.isPartiallySelected ? "minus.circle.fill" : "circle"))
                    .font(.system(size: 12))
                    .foregroundStyle(sub.isFullySelected || sub.isPartiallySelected ? .green : .secondary)
                    .frame(width: 15)
                    .symbolEffect(.bounce, value: sub.isFullySelected)

                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: sub.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    // Which apps a language sub-row covers: the language name
                    // alone does not say what is about to change.
                    if let detail = sub.detail {
                        Text(verbatim: detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .help(sub.detail ?? sub.title)

                Spacer(minLength: 8)

                Text(verbatim: Formatters.bytes(sub.size))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
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
