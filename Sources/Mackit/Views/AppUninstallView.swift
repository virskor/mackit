import SwiftUI
import AppKit

/// The app uninstall tool page.
///
/// Embedded in the main window's detail area like the other tool pages (a
/// card, not full-bleed). The page lists every installed app with its
/// leftover files: one row per app with a tri-state checkbox (the bundle and
/// all residue, or nothing), expandable into the individual residue files so
/// a single leftover can be kept or removed on its own. Uninstalling runs
/// through a confirmation sheet and then the same `CleanEngine` the cleanup
/// scan uses — including the running-app refusal and the shared move-to-Trash
/// preference, which the page passes in from the view model's setting rather
/// than owning a copy.
///
/// Every state-changing step is a button the user presses: entering the page
/// scans once per session, and only the header's rescan re-enumerates.
struct AppUninstallView: View {
    @Environment(AppViewModel.self) private var vm

    private var model: AppUninstallModel { vm.appUninstall }

    /// Which apps are expanded to show their leftover files. View state: the
    /// expansion is presentation, not scan data.
    @State private var expandedIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            // The content claims the rest of the card: without this the list
            // and the loading/empty states would size to their content and
            // the page would read as a thin strip floating above an empty
            // window — the same rule every other page follows.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // The uninstall action sits in a footer bar only while something
            // is checked: a permanently disabled button reads as broken, and
            // an enabled one with nothing selected is a trap.
            if model.phase == .idle, !model.selectedItems.isEmpty {
                Divider()
                footerBar
            }
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
            confirmSheet
        }
        // The progress overlay covers the page while the clean runs, so the
        // list behind stays visible — the same composition the cleanup scan
        // uses.
        .overlay {
            if model.phase == .cleaning {
                CleanProgressOverlay(
                    progress: model.progress,
                    cleanedCount: model.outcomes.filter(\.succeeded).count,
                    currentTitle: model.currentTitle,
                    onStop: { model.cancelClean() }
                )
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: L10n.tr("sidebar.appUninstall"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                if model.hasScanned {
                    Text(verbatim: headerLine)
                        .font(.system(size: 20, weight: .semibold))
                        .lineLimit(1)
                } else if model.isLoading {
                    Text(verbatim: L10n.tr("scan.apps"))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            SearchField(
                text: Binding(
                    get: { model.searchText },
                    set: { model.searchText = $0 }
                ),
                placeholder: L10n.tr("apps.tool.search")
            )
            .frame(width: 200)

            // While the re-scan runs the button swaps its label for a
            // spinner and a "refreshing" title: a disabled button alone
            // reads as "not now" rather than "working on it".
            BrandCTAButton(
                title: model.isLoading
                    ? L10n.tr("apps.tool.rescanning")
                    : L10n.tr("toolbar.rescan"),
                systemImage: "arrow.clockwise",
                style: .secondary,
                compact: true,
                showsProgress: model.isLoading
            ) {
                model.rescan()
            }
            .disabled(model.isLoading || model.phase == .cleaning)
            .help(L10n.tr("apps.tool.rescan.help"))
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    /// "12 apps · 34.2 GB total" — the count answers "is anything installed
    /// here", the total what uninstalling everything listed would remove.
    private var headerLine: String {
        let total = model.apps.reduce(0) { $0 + $1.totalSize }
        return L10n.fmt("apps.tool.header", model.apps.count, Formatters.bytes(total))
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
                    model.rescan()
                }
            )
        case .idle, .confirming, .cleaning:
            if model.isLoading, model.apps.isEmpty {
                loadingState
            } else if model.apps.isEmpty {
                emptyState(
                    title: L10n.tr("apps.tool.empty.title"),
                    message: L10n.tr("apps.tool.empty.message")
                )
            } else if model.visibleApps.isEmpty {
                emptyState(
                    title: L10n.tr("apps.tool.noMatch.title"),
                    message: L10n.tr("apps.tool.noMatch.message")
                )
            } else {
                list
            }
        }
    }

    /// The first scan's state: centered inside the full area, so it reads as
    /// the page's state rather than a strip pinned to the top.
    private var loadingState: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text(verbatim: L10n.tr("scan.apps"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(title: String, message: String) -> some View {
        ContentUnavailableView(
            title,
            systemImage: "square.grid.2x2.fill",
            description: Text(verbatim: message)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.visibleApps) { entry in
                    appRow(entry)

                    if expandedIDs.contains(entry.id) {
                        residueRows(entry)
                    }

                    Divider()
                        .padding(.leading, 46)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - App rows

    private func appRow(_ entry: AppUninstallModel.AppEntry) -> some View {
        let state = model.selectionState(of: entry)
        return HStack(spacing: 10) {
            checkbox(state)
                .onTapGesture { model.setAppSelected(entry, selected: state != .all) }

            // The disclosure only exists when there are leftover files to
            // show; a chevron that expands nothing reads as a broken control.
            if !entry.residues.isEmpty {
                Button {
                    toggleExpanded(entry)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expandedIDs.contains(entry.id) ? 90 : 0))
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 14)
            }

            if let icon = model.icon(forPath: entry.bundle.path) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            } else {
                CategoryIcon(category: .apps)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                // "Version 2.0 · 3 leftover files" — the scanner's own
                // composition, with missing parts omitted.
                Text(verbatim: entry.bundle.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(verbatim: Formatters.bytes(entry.totalSize))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { model.setAppSelected(entry, selected: state != .all) }
        .contextMenu { contextMenu(for: entry) }
    }

    /// The tri-state checkbox: the bundle and all of its residue files, some
    /// of them, or none. The checkmark bounces as it is checked — a toggle
    /// with no motion makes the row feel like a label, not a control.
    private func checkbox(_ state: AppUninstallModel.SelectionState) -> some View {
        Image(systemName: state == .all
            ? "checkmark.circle.fill"
            : (state == .partial ? "minus.circle.fill" : "circle"))
            .font(.system(size: 15))
            .foregroundStyle(state == .none ? Color.secondary : .green)
            .frame(width: 18)
            .symbolEffect(.bounce, value: state == .all)
    }

    private func residueRows(_ entry: AppUninstallModel.AppEntry) -> some View {
        VStack(spacing: 0) {
            ForEach(entry.residues, id: \.id) { item in
                HStack(spacing: 10) {
                    Image(systemName: model.isSelected(item) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(model.isSelected(item) ? .green : Color.secondary.opacity(0.45))
                        .frame(width: 16)
                        .onTapGesture { model.setResidueSelected(item, selected: !model.isSelected(item)) }

                    Text(verbatim: item.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minWidth: 120, alignment: .leading)

                    Text(verbatim: residueLabel(item))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(verbatim: item.abbreviatedPath)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: 240)
                        .help(item.displayPath)

                    Text(verbatim: item.sizeText)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()

                    RiskBadge(risk: item.risk)
                }
                .padding(.leading, 60)
                .padding(.trailing, 12)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .onTapGesture { model.setResidueSelected(item, selected: !model.isSelected(item)) }
            }
        }
    }

    /// The residue kind's own name ("Caches", "Preferences"), the same
    /// localized label the cleanup scan's residue rows used.
    private func residueLabel(_ item: JunkItem) -> String {
        guard case .residue(let kind) = item.appKind else { return "" }
        return L10n.tr(kind.labelKey)
    }

    private func contextMenu(for entry: AppUninstallModel.AppEntry) -> some View {
        let hasResidues = !entry.residues.isEmpty
        return Group {
            // The two uninstall entry points: the checked content is decided
            // by the action, independent of the checkboxes already on screen,
            // so it replaces the selection before entering the confirmation.
            Button(L10n.tr("apps.ctx.uninstallWithResidue"), systemImage: "xmark.circle.fill") {
                model.selectApp(entry)
                model.requestUninstall()
            }
            Button(L10n.tr("apps.ctx.residueOnly"), systemImage: "folder.badge.minus") {
                model.selectAppResidues(entry)
                model.requestUninstall()
            }
            .disabled(!hasResidues)

            Divider()

            Button(L10n.tr("ctx.revealInFinder"), systemImage: "arrow.up.forward.app") {
                vm.revealInFinder(entry.bundle)
            }
            .disabled(entry.bundle.path.isEmpty)
        }
    }

    // MARK: - Footer bar

    private var footerBar: some View {
        HStack(spacing: 12) {
            Text(verbatim: L10n.fmt(
                "apps.tool.selected",
                model.selectedItems.count,
                Formatters.bytes(model.selectedSize)
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Spacer()

            ProminentActionButton(title: L10n.tr("apps.tool.uninstall"), tint: .red) {
                model.requestUninstall()
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
    }

    // MARK: - Confirmation sheet

    private var confirmSheet: some View {
        // Sorted by size from large to small, largest first for easy
        // verification — the cleanup scan's confirmation lists the same way.
        let items = model.selectedItems.sorted { $0.size > $1.size }
        let runningApps = model.runningAppNames
        let leftovers = model.unselectedResidues
        let leftoverCount = leftovers.reduce(0) { $0 + $1.count }
        let leftoverSize = leftovers.reduce(0) { $0 + $1.size }
        let useTrash = vm.moveToTrash

        return VStack(spacing: 0) {
            // Title area
            VStack(spacing: 12) {
                IconBadge(
                    systemImage: "trash.fill",
                    tint: .red,
                    diameter: 56,
                    symbolSize: 24
                )

                VStack(spacing: 5) {
                    Text(verbatim: L10n.tr("apps.confirm.title"))
                        .font(.system(size: 17, weight: .bold))
                    // The copy counts by how many apps are being uninstalled;
                    // residue file rows don't count — otherwise "About to
                    // uninstall 1 app" would show 13.
                    Text(verbatim: L10n.fmt(
                        model.selectedAppCount == 1
                            ? "apps.confirm.summary.one"
                            : "apps.confirm.summary.other",
                        model.selectedAppCount,
                        Formatters.bytes(model.selectedSize)
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 18)

            // Item list: shows all checked items in full, no truncation
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(
                    title: L10n.tr("clean.confirm.list"),
                    trailing: L10n.fmt(
                        items.count == 1
                            ? "clean.confirm.listCount.one"
                            : "clean.confirm.listCount.other",
                        items.count
                    )
                )

                List(items) { item in
                    JunkItemRow(
                        item: item,
                        subtitle: item.abbreviatedPath,
                        icon: icon(for: item),
                        subtitleTruncation: .head
                    )
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .padding(.horizontal, 20)

            // Running apps are skipped by the clean engine; listing them up
            // front avoids a wasted trip
            if !runningApps.isEmpty {
                NoticeRow(
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange,
                    title: L10n.fmt(
                        runningApps.count == 1
                            ? "apps.confirm.running.one"
                            : "apps.confirm.running.other",
                        runningApps.count
                    ),
                    message: runningApps.joined(separator: ", ")
                )
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }

            // Only the app bundle is checked: caches, Application Support and
            // such files would be silently left behind; list the totals here
            // and offer a "Select All" one-tap catch-up
            if !leftovers.isEmpty {
                NoticeRow(
                    systemImage: "folder.badge.questionmark",
                    tint: .orange,
                    title: L10n.tr("apps.confirm.leftoverTitle"),
                    message: L10n.fmt(
                        "apps.confirm.leftoverDetail",
                        leftoverNames(leftovers.map(\.appName)), leftoverCount, Formatters.bytes(leftoverSize)
                    ),
                    action: (
                        L10n.tr("apps.confirm.leftoverAction"),
                        { model.selectResiduesForSelectedApps() }
                    )
                )
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }

            // Uninstall behavior note
            NoticeRow(
                systemImage: "info.circle.fill",
                tint: .accentColor,
                message: L10n.tr("apps.confirm.note")
            )
            .padding(.horizontal, 20)
            .padding(.top, 12)

            // Clean method
            NoticeRow(
                systemImage: useTrash ? "trash" : "bolt.fill",
                message: useTrash
                    ? L10n.tr("clean.confirm.toTrash")
                    : L10n.tr("clean.confirm.permanent")
            )
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Spacer(minLength: 16)

            // Buttons
            HStack(spacing: 10) {
                Button(L10n.tr("common.cancel")) { model.cancelConfirmation() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)

                ProminentActionButton(title: L10n.tr("clean.confirm.uninstall"), tint: .red) {
                    model.beginClean(moveToTrash: useTrash)
                }
            }
            .padding(.bottom, 20)
        }
        .frame(width: 560, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// The real icon for an app bundle; nil for residue rows, which fall
    /// back to the category symbol.
    private func icon(for item: JunkItem) -> NSImage? {
        guard item.appKind == .bundle else { return nil }
        return model.icon(forPath: item.path)
    }

    /// List of app names with missed leftover files; when more than three,
    /// fold into "and N more apps".
    private func leftoverNames(_ names: [String]) -> String {
        let shown = ListFormatter.localizedString(byJoining: Array(names.prefix(3)))
        guard names.count > 3 else { return shown }
        // The fold indicates the number not yet listed, not the total
        return shown + " " + L10n.fmt("apps.confirm.leftoverMore", names.count - 3)
    }

    // MARK: - Expansion

    private func toggleExpanded(_ entry: AppUninstallModel.AppEntry) {
        if expandedIDs.contains(entry.id) {
            expandedIDs.remove(entry.id)
        } else {
            expandedIDs.insert(entry.id)
        }
    }
}
