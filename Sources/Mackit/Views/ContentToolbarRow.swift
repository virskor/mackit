import SwiftUI

/// The toolbar row at the top of the content card: scan, sort, filter, search
/// and clean.
///
/// Deliberately not using the window toolbar (`.toolbar` +
/// `.windowToolbarStyle(.unified)`): that would put the control bar in the
/// title bar's gray area, disconnected from the white rounded card below,
/// looking like two unrelated regions. Placed inside the card, the whole
/// content area reads as one piece, contrasting with the sidebar's flush gray.
///
/// The controls carry explicit styles and `.large` metrics rather than the
/// defaults: left at the default size, a button in this hand-built row
/// renders at text-button weight next to the prominent clean button, and
/// the whole row reads as scaffolding. `.bordered` / `.button` give the
/// actions the system's own macOS 26 control metrics — taller and rounder
/// than before — on every OS. They do not give them Liquid Glass, which
/// the system reserves for its own toolbars and sidebars: the scan button
/// rides `GlassSurface` for that, the same surface the brand CTA and the
/// tray panel's clean button wear.
struct ContentToolbarRow: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm

        HStack(spacing: 10) {
            Button {
                if vm.phase == .scanning {
                    vm.cancelScan()
                } else {
                    vm.startScan()
                }
            } label: {
                // The same glass surface the brand CTA and the tray panel's
                // clean button ride: a `.bordered` button in the content
                // area picks up macOS 26's new control metrics but never
                // Liquid Glass — the system reserves that for its own
                // toolbars and sidebars — so the glass is asked for
                // explicitly. Stop signals the way the system's destructive
                // toolbar items do, with the glyph and label turning red,
                // and NOT with a red-tinted surface: a saturated tint over
                // glass reads as a solid blob and the translucency — the
                // whole point of the surface — stops being visible. Below
                // macOS 26 the fallback keeps the idea as a flat wash at
                // the opacity the badges use.
                GlassSurface(
                    style: .regular,
                    interactive: true,
                    outline: .capsule,
                    fallback: .fill(AnyShapeStyle(
                        vm.phase == .scanning
                            ? Color.red.opacity(0.12)
                            : Color.primary.opacity(0.06)
                    ))
                ) {
                    Label(
                        vm.phase == .scanning
                            ? L10n.tr("toolbar.stopScan")
                            : L10n.tr("toolbar.rescan"),
                        systemImage: vm.phase == .scanning ? "stop.circle" : "arrow.clockwise"
                    )
                    // The `.large` control metrics the bordered button used
                    // to borrow are gone with the bezel, so the label pins
                    // its own size; the padding stands in for the bezel's.
                    .font(.system(size: 13))
                    .foregroundStyle(vm.phase == .scanning ? Color.red : Color.primary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: .command)
            .help(vm.phase == .scanning
                ? L10n.tr("toolbar.stopScanHelp")
                : L10n.tr("toolbar.rescanHelp"))

            Menu {
                ForEach(ItemSort.allCases) { option in
                    Button {
                        vm.sortComparator = option.comparator
                    } label: {
                        if option.comparator == vm.sortComparator {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(verbatim: option.title)
                        }
                    }
                }
            } label: {
                // Names the sort in force rather than a fixed "Sort": the
                // checkmark inside the menu was the only place the current
                // choice showed, and this row is where the user looks.
                // Header clicks land on one of the presets too, so the name
                // stays truthful whichever way the sort was set; the generic
                // label is the fallback for a comparator no preset covers.
                Label(
                    ItemSort(comparator: vm.sortComparator)?.title ?? L10n.tr("toolbar.sort"),
                    systemImage: "arrow.up.arrow.down"
                )
            }
            .menuStyle(.button)
            .controlSize(.large)
            .disabled(vm.items.isEmpty)
            .help(L10n.tr("toolbar.sortHelp"))

            // A bare switch never said what it filtered — the setting it
            // drove showed in a tooltip only, and the sidebar checkbox that
            // used to carry the name is gone. The label puts the name on
            // the control itself, wearing the shield the risk column's
            // "safe" badge wears. The label carries its own size rather
            // than the row's `.large` metrics, which the bordered buttons
            // need to read as buttons; the switch stays at `.regular`,
            // the size the row was tuned to.
            Toggle(isOn: $vm.safeOnly) {
                Label(L10n.tr("toolbar.safeOnly"), systemImage: "checkmark.shield")
                    .font(.system(size: 13))
            }
            .toggleStyle(.switch)
            .controlSize(.regular)
            .disabled(vm.items.isEmpty)
            // Holds the label at its ideal width rather than letting the row
            // squeeze it: this label is the most compressible thing in the
            // row — plain text — so when the row runs over its budget the
            // width deficit lands here, and a squeezed CJK label wraps to one
            // character per line, which reads as a rendering crash. The
            // search field is the element that gives the space back (see
            // searchField); the bordered buttons truncate their labels.
            .fixedSize(horizontal: true, vertical: false)
            // The capsule gives the switch the sort menu's pill chrome:
            // without it the row reads as buttons with a naked switch
            // floating among them. The fill is the search field's, so the
            // row's two hand-built surfaces match. The vertical padding
            // targets the bordered buttons' `.large` height so the pill
            // lines up with them instead of sitting low.
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.45), in: Capsule())
            // Dims with the state rather than leaving a full-strength pill
            // around a dimmed switch: the bordered buttons take the system's
            // disabled treatment, and this capsule has to fade with them.
            .opacity(vm.items.isEmpty ? 0.5 : 1)

            Spacer(minLength: 12)

            searchField

            CleanSummaryButton()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// In-card search field: `.searchable` can only attach to the window
    /// toolbar, so after moving into the card, a custom search field with
    /// equivalent visuals is used (rounded background + magnifying glass +
    /// clear button).
    private var searchField: some View {
        @Bindable var vm = vm

        return HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField(L10n.tr("toolbar.searchPlaceholder"), text: $vm.searchText)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .frame(minWidth: 120)

            if !vm.searchText.isEmpty {
                Button {
                    vm.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("toolbar.clearSearch"))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            .quaternary.opacity(0.45),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        // Flexible rather than a fixed width: the sort button beside it now
        // names the sort in force, which widens the row, and this field is
        // what should give the space back when the window narrows.
        .frame(minWidth: 120, maxWidth: 216)
    }
}
