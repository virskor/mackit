import SwiftUI

/// The large-file analysis tool page: what is taking up the disk, file by
/// file.
///
/// Embedded in the main window's detail area like the other tool pages (a
/// card, not full-bleed). The page walks the startup disk, lists every file
/// at or above the selected size threshold, and moves the checked ones to the
/// Trash through a confirmation sheet and the same `CleanEngine` the cleanup
/// scan uses — including the shared move-to-Trash preference, which the page
/// passes in from the view model's setting rather than owning a copy.
///
/// Screens: a start screen before anything has been walked (a whole-disk
/// traversal is minutes of IO, so the user presses the button rather than the
/// page walking on arrival), and the results once one has. There is no
/// separate full-screen scanning state: hits stream in under a progress strip
/// while the walk runs (see `LargeFilesModel` for why streaming is sound
/// here), so the strip, not a second layout, carries the walk's status.
///
/// The threshold picker and the sort menu live in their own row under the
/// header, visible in every state: before the first walk they configure it,
/// after it they re-run or re-order it.
struct LargeFilesView: View {
    @Environment(AppViewModel.self) private var vm

    private var model: LargeFilesModel { vm.largeFiles }

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
        .background(Color(nsColor: .windowBackgroundColor))
        // The confirmation sheet hangs off the page, driven directly by the
        // model's phase rather than @State + onChange — the latter doesn't
        // trigger on "open again after cancel" because the value didn't
        // change.
        .sheet(isPresented: Binding(
            get: { model.phase == .confirming },
            set: { if !$0 { model.cancelConfirmation() } }
        )) {
            LargeFilesConfirmSheet()
                .environment(vm)
        }
        // The progress overlay covers the page while the clean runs, so the
        // list behind stays visible — the same composition the app uninstall
        // page uses.
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
                Text(verbatim: L10n.tr("largeFiles.title"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                if model.isScanning {
                    Text(verbatim: L10n.tr("largeFiles.scan.title"))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else if model.hasScanned {
                    // "12 个文件 · 共 34.2 GB" — the count answers "is
                    // anything up there", the total what trashing everything
                    // listed would remove.
                    Text(verbatim: summaryLine)
                        .font(.system(size: 20, weight: .semibold))
                        .lineLimit(1)
                } else {
                    // Before the first walk the line states what the walk will
                    // look for — the threshold just picked — so the header is
                    // not a lone small label floating over an empty page.
                    Text(verbatim: L10n.fmt("largeFiles.header.preset", model.threshold.label))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            // The search field belongs in the control row, the same place
            // every other tool page puts it. Hidden until the first hit: a
            // search box over an empty page is a control with nothing to do.
            if !model.files.isEmpty {
                SearchField(
                    text: Binding(
                        get: { model.searchText },
                        set: { model.searchText = $0 }
                    ),
                    placeholder: L10n.tr("largeFiles.tool.search")
                )
                .frame(minWidth: 120, maxWidth: 216)
            }

            // While a walk runs the button becomes "Stop" — the user can
            // always cut a long traversal short, the same contract the disk
            // analysis page's rescan button has. Before the first walk it is
            // hidden entirely: "rescan" is a lie when nothing has been
            // scanned yet, and the start screen's own button is the entry
            // point — the disk analysis page's toolbar waits for its first
            // measurement the same way.
            if model.hasScanned || model.isScanning {
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
                .help(L10n.tr("largeFiles.tool.rescan.help"))
            }

            // The trash action lives in the header, beside the rescan — the
            // same place the app uninstall page puts its uninstall button. A
            // footer bar instead would take its height out of the list the
            // moment something is checked, shifting every row up under the
            // user's cursor. Hidden while nothing is selected — and while a
            // walk runs, because the selection is still streaming and the
            // model refuses the request for exactly that reason. A dimmed
            // red button reads as broken, and an enabled one over a moving
            // list is a trap.
            if model.phase == .idle, !model.isScanning, !model.selectedFiles.isEmpty {
                BrandCTAButton(
                    title: L10n.fmt("largeFiles.tool.trashSelected", model.selectedFiles.count),
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
            "largeFiles.summary.\(model.files.count == 1 ? "one" : "other")",
            model.files.count,
            Formatters.bytes(model.totalSize)
        )
    }

    // MARK: - Threshold & sort row

    private var thresholdRow: some View {
        HStack(spacing: 10) {
            Text(verbatim: L10n.tr("largeFiles.tool.threshold"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            thresholdMenu

            Spacer(minLength: 12)

            // Nothing to order before the first walk — the threshold
            // configures the walk, the sort only means something once hits
            // are landing, so the menu waits for them rather than offering
            // to reorder an empty page.
            if model.hasScanned || model.isScanning {
                sortMenu
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 8)
    }

    /// The threshold menu, showing the current preset. A menu rather than a
    /// segmented control: the three presets sit in one pill beside the sort
    /// menu, and the two read as one control family.
    ///
    /// Disabled while a walk runs: the threshold is baked into the in-flight
    /// traversal, so a click would change the label without changing what is
    /// being collected — the pill says so by refusing the click instead of
    /// lying about it.
    private var thresholdMenu: some View {
        MenuPill {
            Text(verbatim: model.threshold.label)
        } content: {
            ForEach(LargeFilesModel.Threshold.allCases) { preset in
                Button {
                    model.setThreshold(preset)
                } label: {
                    Text(verbatim: preset.label)
                }
            }
        }
        .disabled(model.isScanning)
        .help(L10n.tr("largeFiles.tool.threshold.help"))
    }

    /// The sort menu, labelled with the current order.
    ///
    /// Sorting stays live during a walk — it re-orders the hits that have
    /// landed so far, which is the point of streaming them in.
    private var sortMenu: some View {
        MenuPill {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .medium))

                Text(verbatim: model.sort.title)
            }
        } content: {
            ForEach(LargeFilesModel.Sort.allCases) { option in
                Button {
                    model.sort = option
                } label: {
                    Text(verbatim: option.title)
                }
            }
        }
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
            if !model.hasScanned, !model.isScanning {
                startScreen
            } else if model.files.isEmpty, !model.isScanning {
                emptyState
            } else {
                results
            }
        }
    }

    // MARK: - Start screen

    /// The screen the page shows before anything has been walked — the first
    /// visit, and again after a whole-disk walk is stopped with nothing found.
    /// Walking the startup disk is minutes of IO and a wake-up of every cold
    /// directory, so the page waits for the button instead of starting on
    /// arrival: the user picked the tool, not a traversal.
    private var startScreen: some View {
        HeroPromptView(
            // The scale, the same glyph the sidebar row wears: this tool
            // weighs the disk's files, and one icon across the row and the
            // page gives the tool one identity.
            systemImage: "scalemass.fill",
            brandIcon: false,
            message: L10n.tr("largeFiles.start.explain"),
            messageMaxWidth: 320,
            actionTitle: L10n.tr("welcome.start"),
            actionImage: "arrow.clockwise",
            // The prompt's primary action, the same component the disk
            // analysis page's start screen uses — without it the button does
            // not render at all. Labeled rather than trailing because the
            // footer slot is passed explicitly below, and a trailing closure
            // cannot bind to `action` past a provided `footer`.
            action: { model.startScan() },
            footer: {
                // The TCC-protected home trio is skipped by default —
                // entering one pops the system access dialog, so the opt-in
                // sits where the walk is configured rather than in Settings:
                // the user is about to press the button that would trigger
                // the prompt, which is exactly when the choice is theirs.
                VStack(spacing: 6) {
                    Toggle(isOn: Binding(
                        get: { model.includeProtectedPaths },
                        set: { model.setIncludeProtectedPaths($0) }
                    )) {
                        Text(verbatim: L10n.tr("largeFiles.start.protected"))
                            .font(.system(size: 12))
                    }
                    .toggleStyle(.checkbox)
                    .fixedSize()

                    Text(verbatim: L10n.tr("largeFiles.start.protected.help"))
                        .font(.system(size: 11))
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
            // The walk's status strip, above the hits it is still collecting.
            if model.isScanning {
                scanStrip
                Divider()
            }

            notices

            if model.files.isEmpty {
                streamingHint
            } else {
                list
            }
        }
    }

    /// The walk's status: what it has found, what it is doing right now, how
    /// long it has been at it, and the way out.
    ///
    /// Two lines rather than one row of five readouts: the found count leads
    /// because it is the line the user is waiting for on a minutes-long walk,
    /// and the directory count plus the current path below it answer "is it
    /// actually doing something" without competing for the same line.
    private var scanStrip: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: L10n.fmt(
                    "largeFiles.scan.found.\(model.files.count == 1 ? "one" : "other")",
                    model.files.count,
                    Formatters.bytes(model.totalSize)
                ))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()

                HStack(spacing: 5) {
                    Text(verbatim: L10n.fmt(
                        "largeFiles.scan.directories.\(model.scannedDirectories == 1 ? "one" : "other")",
                        model.scannedDirectories
                    ))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()

                    Text(verbatim: abbreviated(model.scanCurrentPath))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 12)

            Text(verbatim: L10n.fmt("largeFiles.scan.elapsed", Formatters.clock(model.scanElapsed)))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()

            Button(L10n.tr("scan.progress.cancel")) { model.cancelScan() }
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 8)
    }

    /// Shown where the list will be while a walk has found nothing yet: the
    /// area is empty on purpose, and saying why keeps it from reading as a
    /// finished "nothing found" answer mid-walk.
    private var streamingHint: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Text(verbatim: L10n.tr("largeFiles.scan.streaming"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The notices that qualify the list: a stopped walk's hits are partial,
    /// and unreadable folders hold files the walk never saw.
    @ViewBuilder
    private var notices: some View {
        if !model.isScanning, !model.scanCompleted {
            // A stopped walk keeps its hits; saying so keeps a partial list
            // from reading as the complete answer.
            NoticeRow(
                systemImage: "stop.circle",
                tint: .orange,
                message: L10n.tr("largeFiles.partial")
            )
            .padding(.horizontal, 28)
            .padding(.top, 12)
        }

        if model.scanCompleted, model.unreadableDirectories > 0 {
            FullDiskAccessAlert(
                title: L10n.fmt("largeFiles.unreadable.title", model.unreadableDirectories),
                message: L10n.tr("largeFiles.unreadable.message")
            )
            .padding(.horizontal, 28)
            .padding(.top, 12)
        }
    }

    /// The state after a finished walk found nothing at the threshold — or a
    /// stopped walk that had not found anything yet.
    private var emptyState: some View {
        ContentUnavailableView(
            model.scanCompleted
                ? L10n.tr("largeFiles.empty.title")
                : L10n.tr("largeFiles.empty.partial"),
            // The searching-document glyph rather than the hero's plain
            // document: this state is "walked, looked, nothing up there",
            // which is a different message from the start screen's "about
            // to walk".
            systemImage: "doc.text.magnifyingglass",
            description: Text(verbatim: model.scanCompleted
                ? L10n.tr("largeFiles.empty.message")
                : L10n.tr("largeFiles.empty.partial.hint"))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.visibleFiles) { file in
                    fileRow(file)

                    Divider()
                        .padding(.leading, 46)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Rows

    private func fileRow(_ file: LargeFile) -> some View {
        // The whole row is one button — checkbox included — with the house
        // row-press feedback, the same composition the general cleanup
        // module's rows use: a `.plain` row gives no press response on
        // macOS, which makes a long list feel dead. The reveal button is the
        // one exception, overlaid on the row's trailing edge so its clicks
        // never reach the row's own action.
        Button {
            model.setSelected(file, selected: !model.isSelected(file))
        } label: {
            HStack(spacing: 10) {
                checkbox(isSelected: model.isSelected(file))

                Image(nsImage: model.icon(forPath: file.path))
                    .resizable()
                    .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: file.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    // The holding directory, not the full path: the name is
                    // right above it, and "~/Library/Containers" is the part
                    // a user recognizes when deciding whether they need this.
                    Text(verbatim: abbreviated(file.parentPath))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                // The date is the staleness signal: a 2 GB file untouched
                // since 2021 is a deletion candidate, one from yesterday is
                // not.
                //
                // Both trailing columns are fixed-width and right-aligned: a
                // content-sized date ("3 yrs ago" against "yesterday") would
                // shift the size column from row to row, and the sizes are
                // what the list is sorted by — they have to line up to be
                // scannable.
                Text(verbatim: Formatters.relative(file.modified))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(width: 76, alignment: .trailing)

                Text(verbatim: Formatters.bytes(file.size))
                    .font(.system(size: 11, weight: .medium))
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
                    .font(.system(size: 12))
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
            .font(.system(size: 15))
            .foregroundStyle(isSelected ? Color.green : Color.secondary)
            .frame(width: 18)
            .symbolEffect(.bounce, value: isSelected)
    }

    @ViewBuilder
    private func contextMenu(for file: LargeFile) -> some View {
        Button(L10n.tr("ctx.revealInFinder")) { model.revealInFinder(file) }
        Button(L10n.tr("ctx.copyPath")) { Clipboard.copy(file.path) }
        Divider()
        Button(
            model.isSelected(file)
                ? L10n.tr("largeFiles.ctx.deselect")
                : L10n.tr("largeFiles.ctx.select")
        ) {
            model.setSelected(file, selected: !model.isSelected(file))
        }
    }

    /// The home prefix reads shorter and names the same place. The boundary
    /// check keeps a sibling directory whose name merely starts with the
    /// username (/Users/weizhang2) from being abbreviated to ~2.
    private func abbreviated(_ path: String) -> String {
        let home = FileSystem.expand("~")
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
