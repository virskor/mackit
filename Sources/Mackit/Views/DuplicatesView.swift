import SwiftUI

/// The duplicate-file tool page: content that exists more than once.
///
/// Embedded in the main window's detail area like the other tool pages (a
/// card, not full-bleed). The page walks one directory tree, groups files
/// with byte-identical content, and moves the redundant copies to the Trash
/// through a confirmation sheet and the same `CleanEngine` the cleanup scan
/// uses — including the shared move-to-Trash preference, which the page
/// passes in from the view model's setting rather than owning a copy.
///
/// Screens: a start screen before anything has been scanned (a traversal
/// plus content comparison is minutes of IO, so the user presses the button
/// rather than the page scanning on arrival), and the results once one has.
/// There is no separate full-screen scanning state: proven groups stream in
/// under a progress strip while the scan runs, so the strip, not a second
/// layout, carries the scan's status.
///
/// The threshold picker lives in its own row under the header, visible in
/// every state: before the first scan it configures it, after it re-runs it.
struct DuplicatesView: View {
    @Environment(AppViewModel.self) private var vm

    private var model: DuplicatesModel { vm.duplicates }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            thresholdRow

            Divider()

            // The content claims the rest of the card: without this the list
            // and the transient states would size to their content and the
            // page would read as a thin strip floating above an empty window
            // — the same rule every other page follows.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Palette.windowBackground)
        // The confirmation sheet hangs off the page, driven directly by the
        // model's phase rather than @State + onChange — the latter doesn't
        // trigger on "open again after cancel" because the value didn't
        // change.
        .sheet(isPresented: Binding(
            get: { model.phase == .confirming },
            set: { if !$0 { model.cancelConfirmation() } }
        )) {
            DuplicatesConfirmSheet()
                .environment(vm)
        }
        // The progress overlay covers the page while the clean runs, so the
        // list behind stays visible — the same composition the other tools
        // use.
        .overlay {
            if model.phase == .cleaning {
                CleanProgressOverlay(
                    progress: model.progress,
                    cleanedCount: model.cleanedCount,
                    currentTitle: model.currentTitle,
                    onStop: { model.cancelClean() }
                )
            }
        }
        .onChange(of: model.phase) { _, phase in
            // A finished clean freed real space, and the sidebar footer's
            // available-space figure would otherwise stay stale until the
            // next main scan or clean.
            if phase == .done { vm.volumeUsage = .home() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: L10n.tr("duplicateFiles.title"))
                    .font(Theme.Typography.bodyMedium)
                    .foregroundStyle(.secondary)

                if model.isScanning {
                    Text(verbatim: L10n.tr("duplicateFiles.scan.title"))
                        .font(Theme.Typography.pageTitle)
                        .foregroundStyle(.secondary)
                } else if model.hasScanned || !model.groups.isEmpty {
                    // "3 组重复 · 可释放 1.2 GB" — the group count answers
                    // "is anything duplicated", the total what trashing
                    // every redundant copy would return. A first scan that
                    // was stopped after finding groups keeps that summary:
                    // the partial list is still what is on screen.
                    Text(verbatim: summaryLine)
                        .font(Theme.Typography.pageTitle)
                        .lineLimit(1)
                } else {
                    // Before the first scan the line states what the scan
                    // will look for — the threshold just picked — so the
                    // header is not a lone small label floating over an
                    // empty page.
                    Text(verbatim: L10n.fmt("duplicateFiles.header.preset", model.threshold.label))
                        .font(Theme.Typography.pageTitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            // The search field belongs in the control row, the same place
            // every other tool page puts it. Hidden until the first group:
            // a search box over an empty page is a control with nothing to
            // do.
            if !model.groups.isEmpty {
                SearchField(
                    text: Binding(
                        get: { model.searchText },
                        set: { model.searchText = $0 }
                    ),
                    placeholder: L10n.tr("duplicateFiles.tool.search")
                )
                .frame(minWidth: 120, maxWidth: 216)
            }

            // While a scan runs the button becomes "Stop" — the user can
            // always cut a long scan short, the same contract the large-file
            // page's rescan button has. Before the first scan it is hidden
            // entirely: "rescan" is a lie when nothing has been scanned yet,
            // and the start screen's own button is the entry point. A first
            // scan stopped after finding groups is the exception: its
            // partial list stays on screen with no start screen behind it,
            // so the button has to stay reachable.
            if model.hasScanned || model.isScanning || !model.groups.isEmpty {
                BrandCTAButton(
                    title: model.isScanning
                        ? L10n.tr("toolbar.stopScan")
                        : L10n.tr("toolbar.rescan"),
                    systemImage: model.isScanning ? "stop.circle" : "arrow.clockwise",
                    style: .secondary,
                    compact: true,
                    showsProgress: model.isScanning
                ) {
                    model.rescanOrStop()
                }
                .disabled(model.phase == .cleaning)
                .help(L10n.tr("duplicateFiles.tool.rescan.help"))
            }

            // The trash action lives in the header, beside the rescan — the
            // same place the other tool pages put theirs. Hidden while
            // nothing is selected — and while a scan runs, because the
            // selection is still streaming and the model refuses the request
            // for exactly that reason.
            if model.phase == .idle, !model.isScanning, !model.selectedFiles.isEmpty {
                BrandCTAButton(
                    title: L10n.fmt("duplicateFiles.tool.trashSelected", model.selectedFiles.count),
                    systemImage: "trash",
                    destructive: true,
                    compact: true
                ) {
                    model.requestClean()
                }
                .help(L10n.fmt(
                    "apps.tool.selected",
                    model.selectedFiles.count,
                    Formatters.bytes(model.selectedSize)
                ))
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private var summaryLine: String {
        L10n.fmt(
            L10n.plural("duplicateFiles.summary", model.groups.count),
            model.groups.count,
            Formatters.bytes(model.totalWasted)
        )
    }

    // MARK: - Threshold row

    private var thresholdRow: some View {
        HStack(spacing: 10) {
            Text(verbatim: L10n.tr("duplicateFiles.tool.threshold"))
                .font(Theme.Typography.subheadline)
                .foregroundStyle(.secondary)

            thresholdMenu

            // After the first scan the start screen is gone, but the opt-in
            // still has to be reachable: the protected set is baked into the
            // next scan, so the control lives in the always-visible row from
            // then on. Disabled while scanning, like the threshold, because
            // changing it cannot affect the scan already running.
            if !showsStartScreen {
                protectedPathsToggle
                    .disabled(model.isScanning || model.phase == .cleaning)
                    .help(L10n.tr("duplicateFiles.start.protected.help"))
            }

            Spacer(minLength: 12)

            // Nothing to order on the start screen; from the first streaming
            // group on, the sort is live — it re-orders what has landed and
            // never restarts the scan.
            if !showsStartScreen {
                sortMenu
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 8)
    }

    /// The threshold menu, showing the current preset. A menu rather than a
    /// segmented control, matching the large-file page's pill.
    ///
    /// Disabled while a scan runs: the threshold is baked into the in-flight
    /// scan, so a click would change the label without changing what is
    /// being collected — the pill says so by refusing the click instead of
    /// lying about it.
    private var thresholdMenu: some View {
        MenuPill {
            Text(verbatim: model.threshold.label)
        } content: {
            ForEach(DuplicatesModel.Threshold.allCases) { preset in
                Button {
                    model.setThreshold(preset)
                } label: {
                    Text(verbatim: preset.label)
                }
            }
        }
        .disabled(model.isScanning)
        .help(L10n.tr("duplicateFiles.tool.threshold.help"))
    }

    /// The sort menu, labelled with the current order. Sorting stays live
    /// during a scan — a proven group's size is final, so changing the order
    /// re-arranges the groups that have landed instead of waiting for the
    /// comparison to finish.
    private var sortMenu: some View {
        SortMenuPill(
            options: DuplicatesModel.Sort.allCases,
            selection: model.sort,
            optionTitle: { $0.title },
            onSelect: { model.sort = $0 }
        )
    }

    /// The opt-in for the TCC-protected home trio. One control, used both in
    /// the start screen's footer and — once the start screen is gone — in the
    /// always-visible threshold row, so the setting never becomes
    /// unreachable after the first scan.
    private var protectedPathsToggle: some View {
        Toggle(isOn: Binding(
            get: { model.includeProtectedPaths },
            set: { model.setIncludeProtectedPaths($0) }
        )) {
            Text(verbatim: L10n.tr("duplicateFiles.start.protected"))
                .font(Theme.Typography.subheadline)
        }
        .toggleStyle(.checkbox)
        .fixedSize()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .done:
            // The result card takes the page's place, the same as the
            // cleanup scan's result page.
            CleanResultCard(
                reclaimed: model.reclaimed,
                failures: model.outcomes.filter { !$0.succeeded },
                movedToTrash: model.movedToTrash,
                onDone: { model.dismissResult() },
                onRescan: {
                    model.dismissResult()
                    model.startScan()
                }
            )
        case .idle, .confirming, .cleaning:
            if showsStartScreen {
                startScreen
            } else if model.groups.isEmpty, !model.isScanning {
                // A finished scan with no groups can still have failed to
                // read folders or skipped hard links. The empty state says
                // "nothing found"; the notices say how complete that answer
                // actually is, so they belong above it rather than being
                // dropped with the list.
                VStack(spacing: 0) {
                    notices
                    emptyState
                }
            } else {
                results
            }
        }
    }

    /// The first-run screen, and the one a stopped scan returns to when it
    /// never proved a group. A stopped first scan that *did* find groups is
    /// not this state: its partial results stay on screen, under the partial
    /// notice, instead of being replaced by the start prompt.
    private var showsStartScreen: Bool {
        !model.hasScanned && !model.isScanning && model.groups.isEmpty
    }

    // MARK: - Start screen

    /// The screen the page shows before anything has been scanned — the
    /// first visit, and again after the first scan is stopped with nothing
    /// found. Walking the home folder and reading candidate files is minutes
    /// of IO, so the page waits for the button instead of scanning on
    /// arrival: the user picked the tool, not a traversal.
    private var startScreen: some View {
        HeroPromptView(
            // The glyph the sidebar row wears: one icon across the row and
            // the page gives the tool one identity.
            systemImage: "doc.on.doc",
            brandIcon: false,
            message: L10n.tr("duplicateFiles.start.explain"),
            messageMaxWidth: 320,
            actionTitle: L10n.tr("welcome.start"),
            actionImage: "arrow.clockwise",
            // The prompt's primary action, the same component the other
            // start screens use — without it the button does not render at
            // all. Labeled rather than trailing because the footer slot is
            // passed explicitly below, and a trailing closure cannot bind to
            // `action` past a provided `footer`.
            action: { model.startScan() },
            footer: {
                // The TCC-protected home trio is skipped by default —
                // entering one pops the system access dialog, so the opt-in
                // sits where the scan is configured rather than in Settings:
                // the user is about to press the button that would trigger
                // the prompt, which is exactly when the choice is theirs.
                VStack(spacing: 6) {
                    protectedPathsToggle
                    Text(verbatim: L10n.tr("duplicateFiles.start.protected.help"))
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
                .padding(.top, 18)
            }
        )
    }

    // MARK: - Results

    private var results: some View {
        VStack(spacing: 0) {
            // The scan's status strip, above the groups it is still proving.
            if model.isScanning {
                scanStrip
                Divider()
            }

            notices

            if model.visibleGroups.isEmpty {
                // A scan that has not proven a group yet and one whose
                // groups were all filtered away are different answers: the
                // first is still working, the second needs a different
                // search.
                if model.groups.isEmpty {
                    streamingHint
                } else {
                    noMatchState
                }
            } else {
                list
            }
        }
    }

    /// The scan's status. The walk pass leads with the directory count and
    /// the path it is in; the comparison pass leads with the bytes compared
    /// against the budget. Both carry the found count, which is the line the
    /// user is waiting for.
    private var scanStrip: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                if !model.groups.isEmpty {
                    Text(verbatim: L10n.fmt(
                        L10n.plural("duplicateFiles.scan.found", model.groups.count),
                        model.groups.count,
                        Formatters.bytes(model.totalWasted)
                    ))
                    .font(Theme.Typography.subheadlineMedium)
                    .monospacedDigit()
                }

                HStack(spacing: 5) {
                    if model.scanStage == .comparing {
                        Text(verbatim: L10n.tr("duplicateFiles.scan.comparing"))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.tertiary)

                        Text(verbatim: L10n.fmt(
                            "duplicateFiles.scan.compared",
                            Formatters.bytes(model.comparedBytes),
                            Formatters.bytes(model.totalCompareBytes)
                        ))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    } else {
                        Text(verbatim: L10n.fmt(
                            L10n.plural("duplicateFiles.scan.directories", model.scannedDirectories),
                            model.scannedDirectories
                        ))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    }

                    Text(verbatim: Formatters.abbreviateHome(model.scanCurrentPath))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 12)

            Text(verbatim: L10n.fmt("duplicateFiles.scan.elapsed", Formatters.clock(model.scanElapsed)))
                .font(Theme.Typography.footnote)
                .foregroundStyle(.tertiary)
                .monospacedDigit()

            Button(L10n.tr("scan.progress.cancel")) { model.cancelScan() }
                .buttonStyle(.link)
                .font(Theme.Typography.footnote)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 8)
    }

    /// Shown where the list will be while a scan has proven nothing yet: the
    /// area is empty on purpose, and saying why keeps it from reading as a
    /// finished "nothing found" answer mid-scan.
    private var streamingHint: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Text(verbatim: L10n.tr("duplicateFiles.scan.streaming"))
                .font(Theme.Typography.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The notices that qualify the list: a stopped scan's groups are
    /// partial; unreadable folders hold files the scan never saw — but only
    /// while Full Disk Access is missing; and multi-link files were
    /// deliberately left out, which reads as a gap unless it is named.
    @ViewBuilder
    private var notices: some View {
        if !model.isScanning, !model.scanCompleted {
            // A stopped scan keeps its groups; saying so keeps a partial
            // list from reading as the complete answer.
            NoticeRow(
                systemImage: "stop.circle",
                tint: Theme.Palette.warning,
                message: L10n.tr("duplicateFiles.partial")
            )
            .padding(.horizontal, 28)
            .padding(.top, 12)
        }

        if model.scanCompleted, model.unreadableDirectories > 0, !model.fullDiskAccessGranted {
            FullDiskAccessAlert(
                title: L10n.fmt("duplicateFiles.unreadable.title", model.unreadableDirectories),
                message: L10n.tr("duplicateFiles.unreadable.message")
            )
            .padding(.horizontal, 28)
            .padding(.top, 12)
        }

        if model.scanCompleted, model.skippedLinkedFiles > 0 {
            NoticeRow(
                systemImage: "link",
                tint: Theme.Palette.info,
                message: L10n.fmt(
                    L10n.plural("duplicateFiles.skippedHardLinks", model.skippedLinkedFiles),
                    model.skippedLinkedFiles
                )
            )
            .padding(.horizontal, 28)
            .padding(.top, 12)
        }
    }

    /// The state after a finished scan found nothing at the threshold, or a
    /// stopped rescan that follows an earlier finished scan and has not
    /// found anything yet. (A stopped *first* scan with nothing found goes
    /// back to the start screen instead.)
    private var emptyState: some View {
        ContentUnavailableView(
            model.scanCompleted
                ? L10n.tr("duplicateFiles.empty.title")
                : L10n.tr("duplicateFiles.empty.partial"),
            // The searching-document glyph rather than the hero's plain
            // document: this state is "scanned, compared, nothing duplicated",
            // which is a different message from the start screen's "about to
            // scan".
            systemImage: "doc.text.magnifyingglass",
            description: Text(verbatim: model.scanCompleted
                ? L10n.tr("duplicateFiles.empty.message")
                : L10n.tr("duplicateFiles.empty.partial.hint"))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The list exists but the search field hides every group. Without this
    /// the page would show a blank area that reads as "the scan found
    /// nothing" even though clearing the field would bring the list back.
    private var noMatchState: some View {
        ContentUnavailableView(
            L10n.tr("duplicateFiles.noMatch.title"),
            systemImage: "doc.text.magnifyingglass",
            description: Text(verbatim: L10n.tr("duplicateFiles.noMatch.message"))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.visibleGroups) { group in
                    groupHeader(group)
                    ForEach(group.files) { file in
                        fileRow(file)

                        Divider()
                            .padding(.leading, 46)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Rows

    /// A group's header: how many identical copies, and what trashing all
    /// but one returns. The members follow directly below it, so the group
    /// reads as one block.
    private func groupHeader(_ group: DuplicateGroup) -> some View {
        SectionHeader(
            title: L10n.fmt(
                L10n.plural("duplicateFiles.group.files", group.files.count),
                group.files.count,
                Formatters.bytes(group.logicalSize)
            ),
            symbol: "doc.on.doc",
            trailing: L10n.fmt("duplicateFiles.group.wasted", Formatters.bytes(group.wasted))
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func fileRow(_ file: DuplicateFile) -> some View {
        // The whole row is one button — checkbox included — with the house
        // row-press feedback, the same composition the large-file rows use:
        // a `.plain` row gives no press response on macOS, which makes a
        // long list feel dead. The reveal button is the one exception,
        // overlaid on the row's trailing edge so its clicks never reach the
        // row's own action.
        Button {
            model.setSelected(file, selected: !model.isSelected(file))
        } label: {
            HStack(spacing: 10) {
                checkbox(isSelected: model.isSelected(file))

                Image(nsImage: model.icon(forPath: file.path))
                    .resizable()
                    .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: file.name)
                            .font(Theme.Typography.bodyMedium)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        // Marks the copy this tool suggests keeping — an
                        // informational badge, never a check: nothing is
                        // selected on the user's behalf, and this is the
                        // hint they decide against.
                        if model.isKept(file) {
                            Text(verbatim: L10n.tr("duplicateFiles.row.keep"))
                                .font(Theme.Typography.microEmphasis)
                                .foregroundStyle(Theme.Palette.success)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(
                                    Theme.Palette.success.opacity(Theme.Palette.Tint.badge),
                                    in: Capsule()
                                )
                        }
                    }

                    // The holding directory, not the full path: the name is
                    // right above it, and the folder is the part a user
                    // recognizes when deciding which copy they need.
                    Text(verbatim: Formatters.abbreviateHome(file.parentPath))
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                // The date is the "which copy is the original" signal. Both
                // trailing columns are fixed-width and right-aligned, the
                // same rule the large-file rows follow: the sizes have to
                // line up to be scannable.
                Text(verbatim: Formatters.relative(file.modified))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(width: 76, alignment: .trailing)

                Text(verbatim: file.sizeText)
                    .font(Theme.Typography.footnoteMedium)
                    .monospacedDigit()
                    .frame(width: 76, alignment: .trailing)

                // The reveal button's slot, kept empty in the row's own
                // layout: the overlaid button must not push the trailing
                // columns around, and without the reservation the size would
                // slide under it on every row.
                Color.clear.frame(width: 24, height: 20)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .trailing) {
            Button {
                model.revealInFinder(file)
            } label: {
                Image(systemName: "folder")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.tr("ctx.revealInFinder"))
            .padding(.trailing, 12)
        }
        .contextMenu { contextMenu(for: file) }
    }

    private func checkbox(isSelected: Bool) -> some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(Theme.Typography.title3)
            .foregroundStyle(isSelected ? Theme.Palette.success : Theme.Palette.labelSecondary)
            .frame(width: 18)
            .symbolEffect(.bounce, value: isSelected)
    }

    @ViewBuilder
    private func contextMenu(for file: DuplicateFile) -> some View {
        Button(L10n.tr("ctx.revealInFinder")) { model.revealInFinder(file) }
        Button(L10n.tr("ctx.copyPath")) { Clipboard.copy(file.path) }
        Divider()
        Button(
            model.isSelected(file)
                ? L10n.tr("duplicateFiles.ctx.deselect")
                : L10n.tr("duplicateFiles.ctx.select")
        ) {
            model.setSelected(file, selected: !model.isSelected(file))
        }
    }
}
