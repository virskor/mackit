import SwiftUI

/// Sidebar: category list + storage info + module entries.
struct SidebarView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm

        List {
            Section {
                row(
                    symbol: "square.stack.3d.up",
                    tint: .accentColor,
                    title: L10n.tr("sidebar.allItems"),
                    isSelected: itemListIsActive && vm.selectedCategory == nil,
                    figures: (count: vm.developerItemCount, size: vm.developerTotalSize),
                    action: { vm.selectCategory(nil) }
                )
                .help(L10n.tr("sidebar.allItemsHelp"))

                // The general module sits directly under "all items": the two
                // are the window's top-level destinations, while the category
                // rows below only filter the developer list.
                row(
                    symbol: "sparkles",
                    tint: .orange,
                    title: L10n.tr("sidebar.generalCleanup"),
                    isSelected: vm.showsGeneralCleanup,
                    action: { vm.showGeneralCleanup() }
                )
                .help(L10n.tr("scope.general.summary"))
            }

            // Tools sit directly below the cleanup entries, above the
            // developer category filters: they are read-only utilities, a
            // different kind of destination from either cleanup module.
            Section(L10n.tr("sidebar.tools")) {
                row(
                    symbol: "chart.pie",
                    tint: .accentColor,
                    title: L10n.tr("sidebar.diskAnalysis"),
                    isSelected: vm.showsDiskAnalysis,
                    isBusy: vm.diskAnalysis.isScanning,
                    action: { vm.showDiskAnalysis() }
                )
                .help(L10n.tr("sidebar.diskAnalysis.help"))
            }

            if !vm.developerCategories.isEmpty {
                Section(L10n.tr("sidebar.categories")) {
                    ForEach(vm.developerCategories) { category in
                        row(
                            symbol: category.symbol,
                            tint: category.tint,
                            title: category.title,
                            isSelected: itemListIsActive && vm.selectedCategory == category,
                            figures: (
                                count: vm.categoryCounts[category] ?? 0,
                                size: vm.categoryTotals[category] ?? 0
                            ),
                            action: { vm.selectCategory(category) }
                        )
                        .help(category.summary)
                    }
                }
            }

            // The hardware detection and settings entries sit at the very
            // bottom of the list, sharing the same row style as the category
            // rows; clicking switches the right detail area entirely to the
            // corresponding embedded page, not a separate window.
            Section {
                row(
                    symbol: "cpu",
                    tint: .accentColor,
                    title: L10n.tr("hw.title"),
                    isSelected: vm.showsHardware,
                    action: { vm.showHardware() }
                )

                row(
                    symbol: "gear",
                    tint: .accentColor,
                    title: L10n.tr("sidebar.settings"),
                    isSelected: vm.showsSettings,
                    action: { vm.showSettings() }
                )
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

    /// Whether the detail area is on the item list rather than on one of the
    /// module pages. Only then may a category row read as selected: the
    /// sidebar has one selected item at a time, and switching pages has to
    /// clear the highlight.
    private var itemListIsActive: Bool {
        !vm.showsSettings && !vm.showsHardware && !vm.showsGeneralCleanup && !vm.showsDiskAnalysis
    }

    /// One sidebar row: icon, title, and the trailing slot that carries the
    /// figures or the tool's spinner.
    ///
    /// Every row is one line at one height. The cleanup rows used to stack the
    /// item count under the title while the module entries were single-line,
    /// so the list read as two different controls piled on each other — the
    /// count now sits beside the size in the trailing slot instead. That slot
    /// exists on every row whether it is filled or not, so the titles share
    /// one ragged edge and the rows share one height, which is what makes the
    /// sidebar read as a list rather than as a draft.
    ///
    /// The selection follows what the system's own sidebars do now: a light
    /// rounded pill inset from the row's edges, with the row's colors left
    /// alone. An accent-filled row with inverted contents — the treatment the
    /// system used to use — reads as a pressed button sitting among rows that
    /// aren't, and a flat tint of the row's own background read as hover.
    ///
    /// Rows are Buttons with `listRowBackground` rather than `List(selection:)`:
    /// tag selection of an optional value doesn't respond to clicks in a
    /// sidebar List (rows don't react when clicked), and binding the selection
    /// to the checkbox state would let the table's selection write-back clear
    /// the user's picks. Button + background is the known-working pattern.
    private func row(
        symbol: String,
        tint: Color,
        title: String,
        isSelected: Bool,
        /// Item count and total, for the cleanup rows. The module entries
        /// leave it nil — they report their own totals on their pages.
        figures: (count: Int, size: Int64)? = nil,
        /// A measurement is running in the background (the disk analysis
        /// tool). Only the running flag is read, deliberately not the
        /// scanned-directory count, which changes several times a second and
        /// would re-render the whole sidebar for a number the row does not
        /// show.
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                CategoryIcon(symbol: symbol, tint: tint, size: 15, width: 22)

                Text(verbatim: title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let figures {
                    // Fixed rather than flexible: when the sidebar narrows,
                    // the title is what should give way, never the figures.
                    HStack(spacing: 6) {
                        Text(verbatim: L10n.items(figures.count))
                        Text(verbatim: Formatters.bytes(figures.size))
                            .fontWeight(.medium)
                            .monospacedDigit()
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }

                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                // `Color.primary` rather than a hand-mixed white or a fixed
                // gray: it is black in light mode and white in dark mode, so
                // one opacity darkens the pill against the light sidebar and
                // lightens it against the dark one, with the row's own text
                // keeping its contrast either way. A step above the hover
                // fills the rest of the app uses (0.06), so a selected row
                // still reads as more than the one the pointer is over.
                .fill(isSelected ? Color.primary.opacity(0.08) : .clear)
                // Inset from the row's edges the way the system's selection
                // is, so the highlight reads as belonging to the row rather
                // than as a band across the sidebar.
                .padding(.horizontal, 8)
        )
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

                // The brand chip closes the footer on the right, under the
                // capacity line: the storage figures own the top of the block
                // and the app's mark signs it off at the end. The share capsule
                // sits beside it — the same pill, one action away.
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    BrandChip()
                    ShareButton()
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .background(.bar)
    }

    /// The higher the usage ratio, the more alarming the color.
    private var usageTint: Color {
        let fraction = vm.volumeUsage.usedFraction
        if fraction > 0.9 { return .red }
        if fraction > 0.75 { return .orange }
        return .accentColor
    }
}
