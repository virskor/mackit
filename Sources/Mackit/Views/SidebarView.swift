import SwiftUI

/// Sidebar: category list + filter + storage info + module entries.
struct SidebarView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm

        List {
            Section {
                row(
                    category: nil,
                    title: L10n.tr("sidebar.allItems"),
                    symbol: "square.stack.3d.up",
                    tint: .accentColor,
                    count: vm.developerItemCount,
                    size: vm.developerTotalSize
                )
                // The general module sits directly under "all items": the two
                // are the window's top-level destinations, while the category
                // rows below only filter the developer list.
                generalCleanupRow
            }

            // Tools sit directly below the cleanup entries, above the
            // developer category filters: they are read-only utilities, a
            // different kind of destination from either cleanup module.
            Section(L10n.tr("sidebar.tools")) {
                diskAnalysisRow
            }

            if !vm.developerCategories.isEmpty {
                Section(L10n.tr("sidebar.categories")) {
                    ForEach(vm.developerCategories) { category in
                        row(
                            category: category,
                            title: category.title,
                            symbol: category.symbol,
                            tint: category.tint,
                            count: vm.categoryCounts[category] ?? 0,
                            size: vm.categoryTotals[category] ?? 0
                        )
                    }
                }
            }
            Section(L10n.tr("sidebar.filter")) {
                Toggle(L10n.tr("sidebar.safeOnly"), isOn: $vm.safeOnly)
                    .toggleStyle(.checkbox)
                    .padding(.vertical, 2)
            }

            // The hardware detection and settings entries sit at the very
            // bottom of the list, sharing the same row style as the category
            // rows; clicking switches the right detail area entirely to the
            // corresponding embedded page, not a separate window.
            Section {
                hardwareRow
                settingsRow
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            // With the title bar hidden, the system traffic lights and sidebar
            // toggle float above the content; leave space equal in height to
            // the title bar to avoid pressing on the "All Items" row.
            Color.clear.frame(height: 28)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            volumeFooter
        }
        .frame(minWidth: 232)
    }

    /// General cleanup entry row: opens the Lemon-style general module in the
    /// detail area. Same pattern as the hardware row (button + listRowBackground),
    /// without count and size — the module reports its own totals.
    private var generalCleanupRow: some View {
        Button {
            vm.showGeneralCleanup()
        } label: {
            HStack(spacing: 8) {
                CategoryIcon(symbol: "sparkles", tint: .orange, size: 12, width: 18)
                Text(verbatim: L10n.tr("sidebar.generalCleanup"))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            vm.showsGeneralCleanup ? Color.accentColor.opacity(0.15) : Color.clear
        )
        .help(L10n.tr("scope.general.summary"))
    }

    /// Disk analysis tool entry: opens the analysis page in the detail area.
    /// Same pattern as the general cleanup and hardware rows (button +
    /// listRowBackground), without count and size — the page reports its own
    /// totals.
    private var diskAnalysisRow: some View {
        Button {
            vm.showDiskAnalysis()
        } label: {
            HStack(spacing: 8) {
                CategoryIcon(symbol: "chart.pie", tint: .accentColor, size: 12, width: 18)
                Text(verbatim: L10n.tr("sidebar.diskAnalysis"))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            vm.showsDiskAnalysis ? Color.accentColor.opacity(0.15) : Color.clear
        )
        .help(L10n.tr("sidebar.diskAnalysis.help"))
    }

    private func row(
        category: JunkCategory?,
        title: String,
        symbol: String,
        tint: Color,
        count: Int,
        size: Int64
    ) -> some View {
        // Category switching goes through vm.selectCategory: it also dismisses
        // the settings / hardware / clean result pages at the same time.
        // List(selection:) is not used: tag selection of an optional value
        // doesn't respond to clicks in a sidebar List (rows don't react when
        // clicked); button + listRowBackground is a known-working pattern.
        Button {
            vm.selectCategory(category)
        } label: {
            HStack(spacing: 8) {
                CategoryIcon(symbol: symbol, tint: tint, size: 12, width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(verbatim: L10n.items(count))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(verbatim: Formatters.bytes(size))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // When the settings / hardware / general cleanup / disk analysis page
        // is active, no category row is allowed to stay highlighted: the
        // sidebar has only one selected item at a time.
        .listRowBackground(
            !vm.showsSettings && !vm.showsHardware && !vm.showsGeneralCleanup && !vm.showsDiskAnalysis && vm.selectedCategory == category
                ? Color.accentColor.opacity(0.15)
                : Color.clear
        )
        .help(category?.summary ?? L10n.tr("sidebar.allItemsHelp"))
    }

    private var volumeFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(
                    title: L10n.tr("sidebar.startupDisk"),
                    symbol: "internaldrive",
                    trailing: L10n.fmt("sidebar.available", Formatters.bytes(vm.volumeUsage.available))
                )

                UsageBar(fraction: vm.volumeUsage.usedFraction, tint: usageTint)
                    .accessibilityLabel(L10n.fmt(
                        "sidebar.diskUsed", Formatters.percent(vm.volumeUsage.usedFraction)
                    ))

                Text(verbatim: L10n.fmt(
                    "sidebar.totalCapacity", Formatters.bytes(vm.volumeUsage.total)
                ))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .background(.bar)
    }

    /// Hardware detection entry: same pattern as the category and settings rows
    /// (button + listRowBackground), without count and size; clicking switches
    /// to the embedded hardware info page.
    private var hardwareRow: some View {
        Button {
            vm.showHardware()
        } label: {
            HStack(spacing: 8) {
                CategoryIcon(symbol: "cpu", tint: .accentColor, size: 12, width: 18)
                Text(verbatim: L10n.tr("hw.title"))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            vm.showsHardware ? Color.accentColor.opacity(0.15) : Color.clear
        )
    }

    /// Settings entry row: same pattern as the category rows (button +
    /// listRowBackground), without count and size; clicking switches to the
    /// embedded settings page.
    private var settingsRow: some View {
        Button {
            vm.showSettings()
        } label: {
            HStack(spacing: 8) {
                CategoryIcon(symbol: "gear", tint: .accentColor, size: 12, width: 18)
                Text(verbatim: L10n.tr("sidebar.settings"))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            vm.showsSettings ? Color.accentColor.opacity(0.15) : Color.clear
        )
    }

    /// The higher the usage ratio, the more alarming the color.
    private var usageTint: Color {
        let fraction = vm.volumeUsage.usedFraction
        if fraction > 0.9 { return .red }
        if fraction > 0.75 { return .orange }
        return .accentColor
    }
}
