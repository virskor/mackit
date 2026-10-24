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
/// renders at text-button weight next to the prominent clean button, and the
/// whole row reads as scaffolding. `.bordered` / `.button` are also what let
/// the actions pick up the system's own macOS 26 treatment — the same
/// surface family the clean button beside them wears — so the row is one
/// piece on every OS rather than a styled button among naked ones.
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
                Label(
                    vm.phase == .scanning
                        ? L10n.tr("toolbar.stopScan")
                        : L10n.tr("toolbar.rescan"),
                    systemImage: vm.phase == .scanning ? "stop.circle" : "arrow.clockwise"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
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
            .help(L10n.tr("toolbar.safeOnly"))

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
