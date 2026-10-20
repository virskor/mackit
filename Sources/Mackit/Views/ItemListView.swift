import SwiftUI

/// Main list: shows cleanable items as a table, with support for checkboxes,
/// sorting, and a context menu.
struct ItemListView: View {
    @Environment(AppViewModel.self) private var vm

    private var items: [JunkItem] { vm.visibleItems }

    /// The table's own row selection (the blue highlight from clicking / ⌘-clicking),
    /// used only for the context menu.
    /// Deliberately kept separate from the checkbox state vm.selection:
    /// - Table writes its internal selection back to the binding when row identity
    ///   changes; binding directly to vm.selection would clear the user's checkbox
    ///   results (historical bug);
    /// - a binding that reads vm.selection would also make every checkbox toggle
    ///   re-evaluate the entire table.
    /// Row selection is pure UI state; leftover stale ids match no entries, harmless.
    @State private var rowSelection: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            // When results already exist during scanning, hang a progress bar at
            // the top of the list: entries keep growing while being displayed,
            // avoiding the appearance of being stuck during long scans.
            if vm.phase == .scanning {
                ScanBannerView()
                Divider()
            }

            if vm.items.isEmpty {
                ContentUnavailableView(
                    L10n.tr("empty.noItems.title"),
                    systemImage: "checkmark.circle",
                    description: Text(verbatim: L10n.tr("empty.noItems.message"))
                )
            } else if items.isEmpty {
                ContentUnavailableView(
                    L10n.tr("empty.noMatch.title"),
                    systemImage: "magnifyingglass",
                    description: Text(verbatim: L10n.tr("empty.noMatch.message"))
                )
            } else {
                table
            }
        }
        // The cleaning progress overlay lives in ContentView, not here: it has
        // to cover whichever page the clean started from — the general
        // module's rows never render this view, so an overlay hung off it
        // would leave a general-module clean running with no progress at all.
    }

    // MARK: - Table

    private var table: some View {
        // The single source of truth for selection is vm.selection, driven by the
        // checkbox column. Row selection serves only the context menu, deliberately
        // kept separate from the checkbox state: Table writes its internal selection
        // back to the binding when row identity changes; binding directly to
        // vm.selection would clear the user's checkbox results (historical bug), and
        // a binding that reads vm.selection would also make every checkbox toggle
        // re-evaluate the entire table.
        //
        // The write-back is deliberately asynchronous: a synchronous write-back
        // would trigger re-entrant updates inside NSTableView's selection callback,
        // and AppKit warns about reentrant operation (which will become an assertion).
        //
        // The single source of truth for sort order is vm.sortComparator. SwiftUI's
        // Table(sortOrder:) only writes this binding when the user clicks a column
        // header and draws the arrow; the row order is still decided by vm.visibleItems
        // (which sorts by the comparator itself). The row-selection write-back must
        // also be de-duplicated: while scanning, streaming row-identity updates make
        // the table write the (unchanged) selection back repeatedly; without
        // de-duplication this forms a "write-back → change → re-render → write-back"
        // loop that pegs the main thread (measured: CPU at 100% during scans, runtime
        // from 10s up to 60s).
        Table(items, selection: Binding(
            get: { rowSelection },
            set: { new in
                guard new != rowSelection else { return }
                DispatchQueue.main.async { rowSelection = new }
            }
        ), sortOrder: Binding(
            get: { [vm.sortComparator] },
            // An AppKit header click may write multiple comparators (multi-column
            // sorting); only the primary sort is taken. Write-backs equal to the
            // current value are ignored outright — SwiftUI also writes its internal
            // sort state back when the table data changes; without de-duplication
            // this forms a "write-back → change → re-render → write-back" loop
            // (measured: main thread dragged to 100%). The asynchronous write-back
            // guarantees changes don't happen inside NSTableView's delegate callback,
            // eliminating re-entrant warnings at the root.
            set: { new in
                guard let primary = new.first, primary != vm.sortComparator else { return }
                DispatchQueue.main.async { vm.sortComparator = primary }
            }
        )) {
            TableColumn("") { item in
                Image(systemName: vm.isSelected(item) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(vm.isSelected(item) ? Color.accentColor : Color.secondary.opacity(0.45))
                    .contentShape(Rectangle())
                    .onTapGesture { vm.toggle(item) }
            }
            .width(26)

            TableColumn(L10n.tr("table.name"), sortUsing: JunkItemComparator(field: .name, order: .forward)) { item in
                HStack(spacing: 8) {
                    // The app bundle shows its real icon; other entries use the
                    // category symbol
                    if let icon = vm.icon(for: item) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 16, height: 16)
                    } else {
                        CategoryIcon(category: item.category)
                    }
                    ItemTitleBlock(title: item.title, subtitle: item.detail)
                }
            }

            TableColumn(L10n.tr("table.size"), sortUsing: JunkItemComparator(field: .size, order: .forward)) { item in
                Text(verbatim: item.sizeText)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(item.isUnknownSize ? .secondary : .primary)
            }
            .width(84)

            TableColumn(L10n.tr("table.modified"), sortUsing: JunkItemComparator(field: .modified, order: .forward)) { item in
                Text(verbatim: Formatters.relative(item.modified))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .width(96)

            TableColumn(L10n.tr("table.risk")) { item in
                RiskBadge(risk: item.risk)
            }
            .width(74)

            TableColumn(L10n.tr("table.path")) { item in
                Text(verbatim: item.abbreviatedPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(item.displayPath)
            }
            .width(min: 140, ideal: 220, max: 360)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { selected in
            contextMenuItems(for: selected)
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenuItems(for selection: Set<String>) -> some View {
        let selectedItems = vm.items.filter { selection.contains($0.id) }
        let single = selectedItems.count == 1 ? selectedItems[0] : nil

        if let single {
            Button(L10n.tr("ctx.revealInFinder"), systemImage: "arrow.up.forward.app") { vm.revealInFinder(single) }
                .disabled(single.path.isEmpty)
            Button(L10n.tr("ctx.openInTerminal"), systemImage: "terminal") { vm.openInTerminal(single) }
                .disabled(single.path.isEmpty)
            Button(L10n.tr("ctx.copyPath"), systemImage: "doc.on.doc") { vm.copyPath(single) }
            Divider()
            // The two uninstall entry points for the app bundle: the checked
            // content is decided by the action, independent of the checkbox state
            // already in the table, so it directly replaces selection before
            // entering the confirmation panel.
            if single.appKind == .bundle {
                Button(L10n.tr("apps.ctx.uninstallWithResidue"), systemImage: "xmark.circle.fill") { vm.uninstallApp(single) }
                Button(L10n.tr("apps.ctx.residueOnly"), systemImage: "folder.badge.minus") { vm.selectAppResidues(single) }
                    .disabled(vm.residueIDs(for: single).isEmpty)
                Divider()
            }
            Button(L10n.tr("ctx.moveToTrash"), systemImage: "trash", role: .destructive) { vm.trashSingle(single) }
                .disabled(single.path.isEmpty)
            Divider()
        }

        Button(L10n.tr("ctx.selectAll"), systemImage: "checkmark.circle") { vm.selectAllVisible() }
        Button(L10n.tr("ctx.deselectAll"), systemImage: "circle") { vm.deselectAllVisible() }
        Divider()
        Button(L10n.tr("ctx.selectSafeOnly"), systemImage: "checkmark.shield") { vm.selectAllSafe() }
    }
}
