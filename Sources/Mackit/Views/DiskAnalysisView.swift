import SwiftUI

/// The disk analysis tool page: where the space went.
///
/// Layout follows the mockup — a page title carrying the volume's free/total,
/// a toolbar with back/forward, a breadcrumb, rescan and the visualization
/// toggle, then two columns: the current directory's children (left) and the
/// selected child's breakdown as a treemap (right).
///
/// Interaction model, read off the mockup's three states:
/// - the left column lists the breadcrumb's last directory's children, sorted
///   by size descending, each row showing its recursive "N items" count;
/// - clicking a row selects it and the right column shows *its* children as a
///   treemap (Users → weizhang; weizhang's Library → Containers, …);
/// - entering a folder (double-click a row) appends to the breadcrumb, and the
///   largest child is selected automatically so the treemap shows where the
///   space went without a second click.
///
/// The whole child listing is published up front — the user sees every row
/// immediately (the 200 GB folder included) — and sizes stream in afterwards,
/// biggest last, so no long silent wait precedes the first paint.
struct DiskAnalysisView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            toolbar
            Divider()
            HStack(spacing: 0) {
                listColumn
                Divider()
                detailColumn
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
                title: model.isMeasuring || model.isMeasuringSelection
                    ? L10n.tr("toolbar.stopScan")
                    : L10n.tr("toolbar.rescan"),
                systemImage: model.isMeasuring || model.isMeasuringSelection ? "stop.circle" : "arrow.clockwise",
                style: .secondary,
                compact: true,
                glass: true
            ) {
                model.rescanOrStop()
            }

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

    // MARK: - Left column: current directory's children

    private var listColumn: some View {
        let model = vm.diskAnalysis
        return VStack(spacing: 0) {
            if model.children.isEmpty && !model.isMeasuring {
                directoryPlaceholder
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

    /// Shown when the current directory has no children to list: either it
    /// genuinely is empty, or the process may not read it — the two look
    /// identical from the enumeration alone, so they get distinct copy.
    @ViewBuilder
    private var directoryPlaceholder: some View {
        let model = vm.diskAnalysis
        VStack(spacing: 8) {
            Image(systemName: model.unreadable ? "lock.fill" : "folder")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(verbatim: L10n.tr(model.unreadable ? "diskAnalysis.unreadable" : "diskAnalysis.empty"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if model.unreadable {
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
                } else {
                    summary(entry)
                }
            }

            Spacer(minLength: 8)

            if model.isMeasuringSelection {
                ProgressView(
                    value: Double(model.selectionMeasuredCount),
                    total: Double(max(1, model.selectionTotalCount))
                )
                .progressViewStyle(.linear)
                .frame(width: 120)
                .controlSize(.small)
            }
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
                if entry.isSkipped && model.selectedChildren.isEmpty && !model.isMeasuringSelection {
                    // Skipped folders stay unmeasured until the user asks:
                    // measuring one pops the access dialog, and the whole
                    // point of skipping is that it never fires unprompted.
                    // (While an explicit scan is in flight the progress bar
                    // in the header carries the feedback instead.)
                    skippedPlaceholder(entry)
                } else if entry.isUnreadable && model.selectedChildren.isEmpty {
                    selectionPlaceholder(unreadable: true)
                } else if model.selectedChildren.isEmpty && !model.isMeasuringSelection {
                    selectionPlaceholder(unreadable: model.selectionUnreadable)
                } else if model.visualizationMode {
                    TreemapView(
                        entries: model.selectedChildren,
                        icon: { model.icon(forPath: $0) },
                        onEnter: { model.enter($0) },
                        measuringName: model.isMeasuringSelection ? model.selectedEntry?.name : nil
                    )
                } else {
                    // The toggle's off state: the same data as plain rows.
                    entryList(model.selectedChildren)
                }
            } else {
                fileInfo(entry)
            }
        } else if model.isMeasuring {
            measuringPlaceholder
        } else {
            directoryPlaceholder
        }
    }

    /// A TCC-protected folder the scan skipped: why, and the two ways
    /// forward — scan it now (the system's one-time prompt becomes
    /// user-initiated) or grant full access for good.
    private func skippedPlaceholder(_ entry: DiskEntry) -> some View {
        let model = vm.diskAnalysis
        return VStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)

            Text(verbatim: L10n.tr("diskAnalysis.skipped.explain"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            HStack(spacing: 10) {
                BrandCTAButton(
                    title: L10n.tr("diskAnalysis.skipped.action"),
                    systemImage: "arrow.clockwise",
                    style: .secondary,
                    compact: true,
                    glass: true
                ) {
                    model.scanSkippedFolder(entry)
                }

                Button {
                    // The Full Disk Access pane: granting it removes the
                    // prompt entirely for every future scan.
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text(verbatim: L10n.tr("diskAnalysis.openSettings"))
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .help(L10n.tr("diskAnalysis.openSettings.help"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var measuringPlaceholder: some View {
        let model = vm.diskAnalysis
        return VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(verbatim: L10n.fmt(
                "diskAnalysis.measuring",
                model.breadcrumb.last?.name ?? ""
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
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
                        // A pending row keeps the slot with a dash rather than
                        // "0 项", so nothing reflows when the size lands.
                        if entry.isUnreadable {
                            // Never "0 项": a denied folder enumerates empty,
                            // and claiming zero items would be a lie.
                            Label(L10n.tr("diskAnalysis.unreadable"), systemImage: "lock.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else if entry.isSkipped {
                            // Deliberately not measured — see scanSkippedFolder.
                            Label(L10n.tr("diskAnalysis.skipped"), systemImage: "hand.raised")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(verbatim: entry.isMeasured ? L10n.items(entry.itemCount) : "—")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 4)
                Text(verbatim: entry.isMeasured && !entry.isUnreadable && !entry.isSkipped ? Formatters.compactBytes(entry.size) : "—")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if entry.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Still-measuring rows sit back: the measured rows above them are the
        // answer the user came for, and a full-strength placeholder competes
        // with them for attention during a long scan. Skipped rows sit back
        // a little less — their state is settled, just not measured.
        .opacity(entry.isMeasured ? 1 : (entry.isSkipped ? 0.75 : 0.55))
        // The double-click rides along as a simultaneous gesture rather than
        // an onTapGesture on the button: a Button's own tap handling consumes
        // the first click, so a count-2 onTapGesture attached to it never
        // recognizes and the row can't be entered. Simultaneous, both fire —
        // the selection twice (idempotent) and the enter once.
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { model.enter(entry) }
        )
        .help(L10n.tr("diskAnalysis.reveal.help"))
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
    /// The selected folder's name while its children are still measuring —
    /// drives the in-card progress note before any tile can be drawn.
    var measuringName: String?

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
                        .help(L10n.tr("diskAnalysis.reveal.help"))
                    }
                }
                // Tiles need sizes, so the card is blank until the first
                // measurement lands — say what is happening instead of
                // showing an empty rectangle.
                if visibleRects.isEmpty, let measuringName {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(verbatim: L10n.fmt("diskAnalysis.measuring", measuringName))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
