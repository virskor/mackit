import SwiftUI

/// The disk analysis tool page: where the space went.
///
/// Three screens: a start screen before anything has been measured (a
/// whole-disk scan is minutes of IO, so the user presses the button rather
/// than the page scanning on arrival), a scanning screen while a measurement
/// runs (ring, the directory being measured, elapsed time and — once this
/// tree has been scanned before — a remaining estimate, plus a cancel
/// button), and the results once it lands. There is deliberately no
/// incremental presentation — a list that fills in while the user reads it
/// shows numbers that are still moving.
///
/// The results layout follows the mockup — a page title carrying the volume's
/// free/total, a toolbar with back/forward, a breadcrumb, rescan and the
/// visualization toggle, then two columns: the current directory's children
/// (left) and the selected child's breakdown as a treemap (right). The toolbar
/// belongs to the results: before the first scan there is no tree to navigate
/// and nothing to rescan.
///
/// Interaction model:
/// - the left column lists the breadcrumb's last directory's children, sorted
///   by size descending, each row showing its recursive "N items" count;
/// - clicking a row selects it and the right column shows *its* children as a
///   treemap (Users → weizhang; weizhang's Library → Containers, …);
/// - entering a folder (double-click a row) appends to the breadcrumb. Every
///   browsed level is already measured, so the switch is instant — unless the
///   folder sits past the scan's depth budget, in which case entering scans
///   it the same way the whole disk was scanned: scanning screen first,
///   results after.
struct DiskAnalysisView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        let model = vm.diskAnalysis
        return VStack(spacing: 0) {
            titleBar
            // The toolbar navigates the scanned tree — back/forward, the
            // breadcrumb, the home shortcut and the rescan all need one —
            // so it waits for the first scan to land.
            if model.root != nil {
                toolbar
                Divider()
            }
            if model.isScanning {
                scanScreen
            } else if model.root == nil {
                startScreen
            } else {
                results
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Title & toolbar

    /// "磁盘空间分析 - 可用 180.30GB / 共 494.38GB" — the page draws its own
    /// title because the window runs with a hidden title bar.
    private var titleBar: some View {
        let model = vm.diskAnalysis
        return Text(verbatim: L10n.fmt(
            "diskAnalysis.title",
            Formatters.compactBytes(model.volumeUsage.available),
            Formatters.compactBytes(model.volumeUsage.total)
        ))
        .font(.system(size: 13, weight: .medium))
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var toolbar: some View {
        let model = vm.diskAnalysis
        return HStack(spacing: 8) {
            Button {
                model.goBack()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .buttonStyle(.plain)
            .disabled(!model.canGoBack)
            .help(L10n.tr("diskAnalysis.nav.back"))

            Button {
                model.goForward()
            } label: {
                Image(systemName: "chevron.forward")
            }
            .buttonStyle(.plain)
            .disabled(!model.canGoForward)
            .help(L10n.tr("diskAnalysis.nav.forward"))

            breadcrumb

            Spacer(minLength: 12)

            // Home shortcut: the tool's reason to exist for most people is
            // finding junk under ~/Library/Containers, and that is three
            // levels down — one click here skips straight to the home folder.
            Button {
                model.goToHome()
            } label: {
                Label(model.homeName, systemImage: "house")
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .disabled(model.currentPath == model.homePath)
            .help(L10n.tr("diskAnalysis.goToHome.help"))

            // While a measurement is in flight the button becomes "Stop" —
            // same contract as the general module's rescan button: the user
            // can always cut a long traversal short.
            BrandCTAButton(
                title: model.isScanning
                    ? L10n.tr("toolbar.stopScan")
                    : L10n.tr("toolbar.rescan"),
                systemImage: model.isScanning ? "stop.circle" : "arrow.clockwise",
                style: .secondary,
                compact: true,
                glass: true,
                action: { model.rescanOrStop() }
            )

            Toggle(isOn: Binding(
                get: { model.visualizationMode },
                set: { model.visualizationMode = $0 }
            )) {
                Text(verbatim: L10n.tr("diskAnalysis.visualization"))
                    .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(L10n.tr("diskAnalysis.visualization.help"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// The breadcrumb: every segment but the current one is a button that
    /// jumps back to that level; the root carries the disk's real icon.
    private var breadcrumb: some View {
        let model = vm.diskAnalysis
        return HStack(spacing: 5) {
            ForEach(Array(model.breadcrumb.enumerated()), id: \.element.id) { index, entry in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                if index == model.breadcrumb.count - 1 {
                    label(entry, icon: index == 0, weight: .medium)
                } else {
                    Button {
                        model.navigateToBreadcrumb(index: index)
                    } label: {
                        label(entry, icon: index == 0, weight: .regular)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .lineLimit(1)
    }

    private func label(_ entry: DiskEntry, icon: Bool, weight: Font.Weight) -> some View {
        let model = vm.diskAnalysis
        return HStack(spacing: 5) {
            if icon {
                Image(nsImage: model.icon(forPath: entry.path))
                    .resizable()
                    .frame(width: 14, height: 14)
            }
            Text(verbatim: entry.name)
                .font(.system(size: 12, weight: weight))
                .lineLimit(1)
        }
        .truncationMode(.middle)
    }

    // MARK: - Start screen

    /// The screen the page shows before anything has been measured — the first
    /// visit, and again after a whole-disk scan is stopped. Scanning the
    /// startup disk is minutes of IO and a wake-up of every cold directory,
    /// so the page waits for the button instead of starting on arrival: the
    /// user picked the tool, not a traversal. The page title above already
    /// names the tool, so this screen explains what the scan does and hands
    /// over the button.
    private var startScreen: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 22) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)

                Text(verbatim: L10n.tr("diskAnalysis.start.explain"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)

                BrandCTAButton(
                    title: L10n.tr("welcome.start"),
                    systemImage: "arrow.clockwise",
                    style: .primary,
                    glass: true,
                    action: { vm.diskAnalysis.startScan() }
                )
            }

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Scanning screen

    /// The screen the page shows while a measurement runs — the whole disk
    /// from the start screen, a subtree on a drill-down past the depth budget,
    /// one folder on an explicit request.
    ///
    /// What it can say about the wait depends on what is known. The elapsed
    /// readout is always exact. The remaining time needs a total, and a
    /// filesystem walk's total is unknowable up front — so the ring sweeps
    /// until this tree has been scanned once, and from then on divides by the
    /// directory count that scan ended on: the same tree visits the same
    /// directories, so the ring fills and the remaining line extrapolates
    /// from the measured rate. Trees too small to clear the estimate's sample
    /// floors never get a remaining time at all; for them the elapsed readout
    /// is the story.
    private var scanScreen: some View {
        let model = vm.diskAnalysis
        return VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 22) {
                if let fraction = model.scanFraction {
                    ProgressRing(progress: fraction, diameter: 108, lineWidth: 9) {
                        Text(verbatim: Formatters.percent(fraction))
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    .accessibilityElement()
                    .accessibilityLabel(L10n.tr("scan.progress.label"))
                } else {
                    ProgressRing(progress: 0, diameter: 108, lineWidth: 9, isActive: true) {
                        Text(verbatim: "\(model.scannedDirectories)")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    .accessibilityElement()
                    .accessibilityLabel(L10n.tr("scan.progress.label"))
                }

                VStack(spacing: 6) {
                    Text(L10n.tr("diskAnalysis.scan.title"))
                        .font(.system(size: 15, weight: .semibold))
                    Text(verbatim: L10n.fmt("diskAnalysis.scan.current", model.scanCurrentPath))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 460)
                    Text(verbatim: L10n.fmt(
                        "diskAnalysis.scan.count.\(model.scannedDirectories == 1 ? "one" : "other")",
                        model.scannedDirectories
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    Text(verbatim: L10n.fmt("diskAnalysis.scan.elapsed", Formatters.clock(model.scanElapsed)))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    if let remaining = model.scanRemaining {
                        Text(verbatim: L10n.fmt("diskAnalysis.scan.remaining", Formatters.clock(remaining)))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }

                Button(L10n.tr("scan.progress.cancel")) { model.cancelScan() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Results

    private var results: some View {
        HStack(spacing: 0) {
            listColumn
            Divider()
            detailColumn
        }
    }

    // MARK: - Left column: current directory's children

    private var listColumn: some View {
        let model = vm.diskAnalysis
        return VStack(spacing: 0) {
            if model.currentEntry?.isUnreadable == true {
                directoryPlaceholder(unreadable: true)
            } else if model.children.isEmpty {
                if model.currentEntry?.isTruncated == true {
                    // The folder was entered but its scan was stopped: say so
                    // and offer it again, rather than claiming "empty folder".
                    notScannedPlaceholder(
                        title: L10n.tr("diskAnalysis.truncated.action"),
                        action: { model.scanCurrentFolder() }
                    )
                } else {
                    directoryPlaceholder(unreadable: false)
                }
            } else {
                List {
                    ForEach(model.children) { entry in
                        entryRow(entry)
                            .listRowBackground(
                                model.selectedID == entry.id ? Color.accentColor.opacity(0.15) : Color.clear
                            )
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 300)
    }

    /// Shown where a listing should be but the scan never landed: the browsed
    /// folder's children were never measured — the depth budget cut them, or
    /// the scan that would have expanded them was stopped.
    private func notScannedPlaceholder(title: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "internaldrive")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(verbatim: L10n.tr("diskAnalysis.notScanned"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            BrandCTAButton(
                title: title,
                systemImage: "arrow.clockwise",
                style: .secondary,
                compact: true,
                glass: true,
                action: action
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shown when the current directory has no children to list: either it
    /// genuinely is empty, or the process may not read it — the two look
    /// identical from the enumeration alone, so they get distinct copy.
    @ViewBuilder
    private func directoryPlaceholder(unreadable: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: unreadable ? "lock.fill" : "folder")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(verbatim: L10n.tr(unreadable ? "diskAnalysis.unreadable" : "diskAnalysis.empty"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if unreadable {
                Text(verbatim: L10n.tr("diskAnalysis.fdaHint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 220)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Right column: the selected child's breakdown

    private var detailColumn: some View {
        VStack(spacing: 0) {
            detailHeader
            Divider()
            detailContent
        }
    }

    private var detailHeader: some View {
        let model = vm.diskAnalysis
        return HStack(spacing: 10) {
            Text(verbatim: model.selectedEntry?.name ?? model.breadcrumb.last?.name ?? "")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            if let entry = model.selectedEntry {
                // An unreadable folder has no counts to report — the summary
                // says so rather than claiming "0 folders 0 files".
                if entry.isUnreadable {
                    Label(L10n.tr("diskAnalysis.unreadable"), systemImage: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if entry.isSkipped {
                    Label(L10n.tr("diskAnalysis.skipped"), systemImage: "hand.raised")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if entry.isTruncated {
                    Label(L10n.tr("diskAnalysis.truncated"), systemImage: "questionmark.folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    summary(entry)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// "2 文件夹 1 文件 共 206.53GB": the counts and the unit words are tinted
    /// orange per the mockup, the total stays secondary.
    private func summary(_ entry: DiskEntry) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: L10n.fmt(
                "diskAnalysis.header.folders.\(entry.folderCount == 1 ? "one" : "other")",
                entry.folderCount
            ))
            Text(verbatim: L10n.fmt(
                "diskAnalysis.header.files.\(entry.fileCount == 1 ? "one" : "other")",
                entry.fileCount
            ))
            .foregroundStyle(.orange)
            Text(verbatim: L10n.fmt("diskAnalysis.header.total", Formatters.compactBytes(entry.size)))
        }
        .font(.system(size: 11))
        .monospacedDigit()
    }

    @ViewBuilder
    private var detailContent: some View {
        let model = vm.diskAnalysis
        if let entry = model.selectedEntry {
            if entry.isDirectory {
                if entry.isSkipped {
                    // Skipped folders stay unmeasured until the user asks:
                    // measuring one pops the access dialog, and the whole
                    // point of skipping is that it never fires unprompted.
                    scanPromptPlaceholder(
                        icon: "hand.raised.fill",
                        explain: L10n.tr("diskAnalysis.skipped.explain"),
                        actionTitle: L10n.tr("diskAnalysis.skipped.action"),
                        action: { model.scanFolder(entry) },
                        settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
                    )
                } else if entry.isUnreadable {
                    selectionPlaceholder(unreadable: true)
                } else if entry.isTruncated {
                    // The size is real but the children were not retained, so
                    // the treemap has nothing to draw until the folder is
                    // scanned. Selecting a row never starts a scan on its own
                    // — a single click must not commit to a long traversal.
                    scanPromptPlaceholder(
                        icon: "questionmark.folder",
                        explain: L10n.tr("diskAnalysis.truncated.explain"),
                        actionTitle: L10n.tr("diskAnalysis.truncated.action"),
                        action: { model.scanFolder(entry) }
                    )
                } else if entry.children.isEmpty {
                    selectionPlaceholder(unreadable: false)
                } else if model.visualizationMode {
                    if entry.children.contains(where: { $0.size > 0 }) {
                        TreemapView(
                            entries: entry.children,
                            icon: { model.icon(forPath: $0) },
                            onEnter: { model.enter($0) }
                        )
                    } else {
                        // Every child measures zero (empty subfolders): there
                        // is no area to draw, and a blank card reads as broken.
                        selectionPlaceholder(unreadable: false)
                    }
                } else {
                    // The toggle's off state: the same data as plain rows.
                    entryList(entry.children)
                }
            } else {
                fileInfo(entry)
            }
        } else {
            directoryPlaceholder(unreadable: false)
        }
    }

    /// The detail column's prompt for a folder whose children are not in the
    /// tree: TCC-protected ones the scan skips by design, and ones the depth
    /// budget cut. Both offer the explicit scan — the only difference is the
    /// copy and the settings link the protected one adds.
    private func scanPromptPlaceholder(
        icon: String,
        explain: String,
        actionTitle: String,
        action: @escaping () -> Void,
        settingsURL: URL? = nil
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)

            Text(verbatim: explain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            HStack(spacing: 10) {
                BrandCTAButton(
                    title: actionTitle,
                    systemImage: "arrow.clockwise",
                    style: .secondary,
                    compact: true,
                    glass: true,
                    action: action
                )

                if let settingsURL {
                    Button {
                        // The Full Disk Access pane: granting it removes the
                        // prompt entirely for every future scan.
                        NSWorkspace.shared.open(settingsURL)
                    } label: {
                        Text(verbatim: L10n.tr("diskAnalysis.openSettings"))
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .help(L10n.tr("diskAnalysis.openSettings.help"))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func selectionPlaceholder(unreadable: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: unreadable ? "lock.fill" : "folder")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(verbatim: L10n.tr(unreadable ? "diskAnalysis.unreadable" : "diskAnalysis.empty"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if unreadable {
                Text(verbatim: L10n.tr("diskAnalysis.fdaHint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A selected file has no children to break down; its size and name are
    /// all the analysis knows, so that is all this shows.
    private func fileInfo(_ entry: DiskEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent(L10n.tr("table.name")) {
                Text(verbatim: entry.name)
            }
            LabeledContent(L10n.tr("table.size")) {
                Text(verbatim: Formatters.compactBytes(entry.size))
                    .monospacedDigit()
            }
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Rows

    /// One child row: workspace icon, name with its recursive item count, the
    /// measured size, and the disclosure chevron on folders. Single click
    /// selects, double click enters the folder (the chevron is that
    /// affordance; files have none — there is nothing to enter).
    private func entryRow(_ entry: DiskEntry) -> some View {
        let model = vm.diskAnalysis
        return Button {
            model.select(entry.id)
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: model.icon(forPath: entry.path))
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: entry.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if entry.isDirectory {
                        if entry.isUnreadable {
                            // Never "0 项": a denied folder enumerates empty,
                            // and claiming zero items would be a lie.
                            Label(L10n.tr("diskAnalysis.unreadable"), systemImage: "lock.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else if entry.isSkipped {
                            // Deliberately not measured — see scanFolder.
                            Label(L10n.tr("diskAnalysis.skipped"), systemImage: "hand.raised")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            // Known even past the depth budget: the level is
                            // enumerated, only its nodes are not retained.
                            Text(verbatim: L10n.items(entry.itemCount))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 4)
                Text(verbatim: entry.isSkipped || entry.isUnreadable ? "—" : Formatters.compactBytes(entry.size))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if entry.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            // Content inset, selection full-bleed — the sidebar's pattern, and
            // the page's 16pt rhythm: the icon and the size line up with the
            // toolbar's padding instead of touching the window edge and the
            // column divider.
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A row the scan skipped sits back: its state is settled, just not
        // measured, and a full-strength row competes with the measured ones
        // for attention.
        .opacity(entry.isSkipped ? 0.75 : 1)
        // The double-click rides along as a simultaneous gesture rather than
        // an onTapGesture on the button: a Button's own tap handling consumes
        // the first click, so a count-2 onTapGesture attached to it never
        // recognizes and the row can't be entered. Simultaneous, both fire —
        // the selection twice (idempotent) and the enter once.
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { model.enter(entry) }
        )
        // The tip describes what a click does; revealing in Finder lives in
        // the context menu and needs no hover hint.
        .help(entry.isDirectory
            ? L10n.tr("diskAnalysis.enter.help")
            : L10n.tr("diskAnalysis.select.help"))
        .contextMenu {
            Button {
                model.revealInFinder(entry)
            } label: {
                Label(L10n.tr("ctx.revealInFinder"), systemImage: "arrow.forward.circle")
            }
        }
    }

    /// The same row inside the detail column, for the visualization toggle's
    /// off state.
    private func entryList(_ entries: [DiskEntry]) -> some View {
        List {
            ForEach(entries) { entry in
                entryRow(entry)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
    }
}

/// The treemap: the selected folder's children as area-proportional tiles.
///
/// Layout is a pure function (`TreemapLayout`); this only renders the rects
/// it returns. Tiles too small to carry a label render bare — a directory can
/// hold hundreds of children, and label collision would be worse than a
/// blank tile.
private struct TreemapView: View {
    let entries: [DiskEntry]
    let icon: (String) -> NSImage
    let onEnter: (DiskEntry) -> Void

    /// Which tile is highlighted. Local to the view on purpose: a tile is a
    /// *grandchild* of the browsed directory (the treemap shows the selected
    /// child's children), so it cannot become the model's selection — that
    /// would re-root the treemap. Clicking highlights, double-clicking enters.
    @State private var selectedID: String?

    var body: some View {
        GeometryReader { geometry in
            let rects = TreemapLayout.layout(
                items: entries.map { (id: $0.id, size: $0.size) },
                in: geometry.size
            )
            // A tile this small is invisible and unclickable; skipping them
            // keeps a directory with thousands of children (node_modules,
            // caches) from building thousands of views for nothing.
            let visibleRects = rects.filter { $0.value.width >= 2 && $0.value.height >= 2 }
            ZStack(alignment: .topLeading) {
                ForEach(entries) { entry in
                    if let rect = visibleRects[entry.id] {
                        TreemapTile(
                            entry: entry,
                            icon: icon(entry.path),
                            isSelected: entry.id == selectedID,
                            onSelect: { selectedID = entry.id },
                            onEnter: { onEnter(entry) }
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        // Only folders can be entered, so only they advertise
                        // it. The rows carry a chevron for the same affordance;
                        // a treemap tile has no room for one, and the old
                        // "Reveal in Finder" tip described the context menu's
                        // action, not what a click does.
                        .help(entry.isDirectory
                            ? L10n.tr("diskAnalysis.enter.help")
                            : L10n.tr("diskAnalysis.select.help"))
                    }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// One treemap tile: rounded fill with a 2pt inset (the gap between tiles),
/// carrying the folder icon, name and size when there is room for them.
private struct TreemapTile: View {
    let entry: DiskEntry
    let icon: NSImage
    let isSelected: Bool
    let onSelect: () -> Void
    let onEnter: () -> Void

    @State private var isHovered = false

    /// How much label the tile can carry, read off the rect the layout gave
    /// it: a tile smaller than its own text reads as noise.
    enum Room {
        case none, name, full
    }

    var body: some View {
        GeometryReader { geometry in
            let room = Self.room(for: geometry.size)
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

            ZStack {
                shape.fill(fill)
                if isSelected {
                    shape.strokeBorder(Color.accentColor, lineWidth: 1.5)
                }
            }
            .padding(2)
            .overlay {
                label(for: room)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect() }
        .onTapGesture(count: 2) { onEnter() }
        .accessibilityLabel("\(entry.name), \(Formatters.compactBytes(entry.size))")
    }

    private static func room(for size: CGSize) -> Room {
        if size.width >= 96, size.height >= 64 { return .full }
        if size.width >= 48, size.height >= 28 { return .name }
        return .none
    }

    private var fill: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        if isHovered { return Color.primary.opacity(0.12) }
        return Color.primary.opacity(0.07)
    }

    @ViewBuilder
    private func label(for room: Room) -> some View {
        switch room {
        case .full:
            VStack(spacing: 3) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 22, height: 22)
                Text(verbatim: entry.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(verbatim: Formatters.compactBytes(entry.size))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 4)
        case .name:
            Text(verbatim: entry.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 4)
        case .none:
            EmptyView()
        }
    }
}
