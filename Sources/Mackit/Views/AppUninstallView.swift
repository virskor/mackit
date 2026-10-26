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
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // The confirmation sheet hangs off the page, driven directly by the
        // model's phase rather than @State + onChange — the latter doesn't
        // trigger on "open again after cancel" because the value didn't
        // change. Its content is a view of its own so it re-renders when the
        // selection moves under it (see AppUninstallConfirmSheet).
        .sheet(isPresented: Binding(
            get: { model.phase == .confirming },
            set: { if !$0 { model.cancelConfirmation() } }
        )) {
            AppUninstallConfirmSheet()
                .environment(vm)
        }
        // The progress overlay covers the page while the clean runs, so the
        // list behind stays visible — the same composition the cleanup scan
        // uses.
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
            // A finished uninstall freed real space, and the sidebar footer's
            // available-space figure would otherwise stay stale until the
            // next main scan or clean.
            if phase == .done { vm.volumeUsage = .home() }
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

            // The search field belongs in the control row, the same place the
            // developer list's toolbar puts it — the page's controls then read
            // as one row on every page. Flexible rather than a fixed width:
            // when the window narrows, this field gives the space back and the
            // title truncates, the trade the toolbar row makes too.
            SearchField(
                text: Binding(
                    get: { model.searchText },
                    set: { model.searchText = $0 }
                ),
                placeholder: L10n.tr("apps.tool.search")
            )
            .frame(minWidth: 120, maxWidth: 216)

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

            // The uninstall action lives in the header, beside the rescan —
            // the same place the general module puts its clean button. A
            // footer bar instead would take its height out of the list the
            // moment something is checked, shifting every row up under the
            // user's cursor. Hidden while nothing is selected rather than
            // shown disabled: a dimmed red button reads as broken, and an
            // enabled one with nothing selected is a trap. The header's own
            // height is set by the title block, so the button appearing
            // never moves the list.
            if model.phase == .idle, !model.selectedItems.isEmpty {
                BrandCTAButton(
                    title: L10n.fmt("apps.tool.uninstallSelected", model.selectedItems.count),
                    systemImage: "trash",
                    destructive: true,
                    compact: true
                ) {
                    model.requestUninstall()
                }
                .help(L10n.fmt(
                    "apps.tool.selected",
                    model.selectedItems.count,
                    Formatters.bytes(model.selectedSize)
                ))
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    /// "12 apps · 34.2 GB total" — the count answers "is anything installed
    /// here", the total what uninstalling everything listed would remove.
    ///
    /// The total deduplicates by item id: an app installed in both
    /// `/Applications` and `~/Applications` claims the same residue files on
    /// both of its rows, and those bytes exist once.
    private var headerLine: String {
        var seen = Set<String>()
        var total: Int64 = 0
        for entry in model.apps {
            total += entry.bundle.size
            for residue in entry.residues where seen.insert(residue.id).inserted {
                total += residue.size
            }
        }
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
        VStack(spacing: 0) {
            // The last-used dates live in the Spotlight index, which a
            // process without Full Disk Access cannot read; the page says so
            // instead of presenting "never opened" for every app — the same
            // honest-degradation shape the disk analysis tool uses for its
            // unreadable folders.
            if model.lastOpenedUnreadable {
                FullDiskAccessAlert(
                    title: L10n.tr("apps.tool.lastOpenedUnavailable"),
                    message: L10n.tr("apps.tool.lastOpenedUnavailableHint")
                )
                .padding(.horizontal, 28)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }

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
    }

    // MARK: - App rows

    private func appRow(_ entry: AppUninstallModel.AppEntry) -> some View {
        let state = model.selectionState(of: entry)
        // Three sibling buttons, never nested gestures: the row used to be one
        // onTapGesture with the checkbox and the chevron inside it, so a tap
        // on the chevron fired the expand *and* the select — the two actions
        // fought over every click. One button per action is the pattern the
        // disk analysis rows and the general module's row switches use.
        //
        // The order matches the general module's rows — checkbox first — so
        // the two lists' checkboxes share one column when the user flips
        // between them; the disclosure sits between the checkbox and the app
        // it opens.
        return HStack(spacing: 10) {
            // Select: the checkbox, the same leading-edge position the general
            // module's row switch occupies.
            Button {
                model.setAppSelected(entry, selected: state != .all)
            } label: {
                checkbox(state)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expand. A row with no leftovers keeps the column so every row's
            // app icons share one left edge. The glyph is 14pt; the padding
            // gives it a 24pt hit target.
            if !entry.residues.isEmpty {
                Button {
                    toggleExpanded(entry)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expandedIDs.contains(entry.id) ? 90 : 0))
                        .frame(width: 14, height: 14)
                        .padding(5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 14).padding(5)
            }

            // Select: the app's icon, name and size — the same action's click
            // target as the checkbox, the way the general module's row switch
            // makes the whole row the toggle.
            Button {
                model.setAppSelected(entry, selected: state != .all)
            } label: {
                HStack(spacing: 10) {
                    // The app's real icon, drawn at 24: this page is where
                    // the user picks an app to remove, and a 16pt thumbnail
                    // next to a 13pt name reads as a list of paths rather
                    // than of apps.
                    if let icon = model.icon(forPath: entry.bundle.path) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 24, height: 24)
                    } else {
                        CategoryIcon(category: .apps, size: 18, width: 24)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: entry.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        // "Version 2.0 · 3 leftover files" — the scanner's
                        // own composition, with missing parts omitted.
                        Text(verbatim: entry.bundle.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        lastOpenedLine(entry)
                    }

                    Spacer(minLength: 8)

                    Text(verbatim: Formatters.bytes(entry.totalSize))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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

    /// "Last opened 3 days ago" — the signal that says whether an app is
    /// still worth keeping, which is the question this page exists to
    /// answer. An app with no date on a machine where the dates are
    /// readable was never launched; when they are unreadable the line is
    /// omitted rather than claiming a history the system did not give us.
    @ViewBuilder
    private func lastOpenedLine(_ entry: AppUninstallModel.AppEntry) -> some View {
        if let lastOpened = entry.lastOpened {
            Text(verbatim: L10n.fmt("apps.tool.lastOpened", Formatters.relative(lastOpened)))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        } else if !model.lastOpenedUnreadable {
            Text(verbatim: L10n.tr("apps.tool.neverOpened"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private func residueRows(_ entry: AppUninstallModel.AppEntry) -> some View {
        VStack(spacing: 0) {
            ForEach(entry.residues, id: \.id) { item in
                // One button for the whole row, the checkbox a passive
                // indicator inside it — the same shape as the general
                // module's sub-rows. The row used to nest the checkbox's own
                // tap inside the row's, so a click on the checkbox toggled
                // twice and nothing happened.
                Button {
                    model.setResidueSelected(item, selected: !model.isSelected(item))
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: model.isSelected(item) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13))
                            .foregroundStyle(model.isSelected(item) ? .green : Color.secondary.opacity(0.45))
                            .frame(width: 16)

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
                }
                .buttonStyle(.plain)
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

    // MARK: - Expansion

    private func toggleExpanded(_ entry: AppUninstallModel.AppEntry) {
        if expandedIDs.contains(entry.id) {
            expandedIDs.remove(entry.id)
        } else {
            expandedIDs.insert(entry.id)
        }
    }
}
