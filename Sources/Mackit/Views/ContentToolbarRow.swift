import SwiftUI

/// The toolbar row at the top of the content card: scan, sort, filter, search
/// and clean.
///
/// Deliberately not using the window toolbar (`.toolbar` +
/// `.windowToolbarStyle(.unified)`): that would put the control bar in the
/// title bar's gray area, disconnected from the white rounded card below,
/// looking like two unrelated regions. Placed inside the card, the whole
/// content area reads as one piece, contrasting with the sidebar's flush gray.
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
                Label(L10n.tr("toolbar.sort"), systemImage: "arrow.up.arrow.down")
            }
            .disabled(vm.items.isEmpty)
            .help(L10n.tr("toolbar.sortHelp"))

            Toggle(L10n.tr("toolbar.safeOnly"), isOn: $vm.safeOnly)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(vm.items.isEmpty)
                .help(L10n.tr("toolbar.safeOnly"))

            Spacer(minLength: 12)

            searchField

            CleanSummaryButton()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// In-card search field: `.searchable` can only attach to the window
    /// toolbar, so after moving into the card, a custom search field with
    /// equivalent visuals is used (rounded background + magnifying glass +
    /// clear button).
    private var searchField: some View {
        @Bindable var vm = vm

        return HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField(L10n.tr("toolbar.searchPlaceholder"), text: $vm.searchText)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .frame(minWidth: 120)

            if !vm.searchText.isEmpty {
                Button {
                    vm.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("toolbar.clearSearch"))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            .quaternary.opacity(0.45),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .frame(width: 200)
    }
}
