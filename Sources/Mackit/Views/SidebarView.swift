import SwiftUI

/// Sidebar: the window's destinations — the two cleanup entries and the
/// tools — plus the storage footer. The developer categories are not here:
/// they filter the item list, so they sit in that page's own rail (see
/// CategoryRailView).
struct SidebarView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm

        List {
            Section {
                row(
                    icon: .symbol("square.stack.3d.up"),
                    tint: .accentColor,
                    title: L10n.tr("sidebar.allItems"),
                    isSelected: itemListIsActive && vm.selectedCategory == nil,
                    figures: (count: vm.developerItemCount, size: vm.developerTotalSize),
                    action: { vm.selectCategory(nil) }
                )
                .help(L10n.tr("sidebar.allItemsHelp"))

                // The general module sits directly under "all items": the two
                // are the window's top-level destinations. The category
                // filters are not among them — they filter the item list, so
                // they live in that page's own rail (see CategoryRailView).
                row(
                    icon: .symbol("sparkles"),
                    tint: .orange,
                    title: L10n.tr("sidebar.generalCleanup"),
                    isSelected: vm.showsGeneralCleanup,
                    // A cleanup destination like "all items", not a tool: it
                    // reports what its own scan found in the same trailing
                    // slot, live, the way the "all items" row does.
                    figures: (count: vm.generalItemCount, size: vm.generalTotalSize),
                    action: { vm.showGeneralCleanup() }
                )
                .help(L10n.tr("scope.general.summary"))
            }

            // Tools sit directly below the cleanup entries, above the
            // developer category filters: they are utilities, a different
            // kind of destination from either cleanup module — overviews
            // with their own housekeeping actions, not scan-driven cleaning.
            // Hardware detection belongs among them for the same reason: a
            // read-only report about the machine, nothing to clean.
            Section(L10n.tr("sidebar.tools")) {
                row(
                    icon: .symbol("chart.pie"),
                    tint: .accentColor,
                    title: L10n.tr("sidebar.diskAnalysis"),
                    isSelected: vm.showsDiskAnalysis,
                    isBusy: vm.diskAnalysis.isScanning,
                    action: { vm.showDiskAnalysis() }
                )
                .help(L10n.tr("sidebar.diskAnalysis.help"))

                // The large-file tool sits directly under the disk analysis:
                // the two answer the same question at different resolutions,
                // "where did the space go" by tree and by individual file, so
                // they are one click apart in either direction.
                row(
                    icon: .symbol("scalemass.fill"),
                    tint: .accentColor,
                    title: L10n.tr("sidebar.largeFiles"),
                    isSelected: vm.showsLargeFiles,
                    isBusy: vm.largeFiles.isScanning,
                    action: { vm.showLargeFiles() }
                )
                .help(L10n.tr("sidebar.largeFiles.help"))

                row(
                    icon: .symbol("shippingbox"),
                    tint: .accentColor,
                    title: L10n.tr("sidebar.homebrew"),
                    isSelected: vm.showsHomebrew,
                    isBusy: vm.homebrew.isLoading,
                    action: { vm.showHomebrew() }
                )
                .help(L10n.tr("sidebar.homebrew.help"))

                row(
                    icon: .symbol("cpu"),
                    tint: .accentColor,
                    title: L10n.tr("hw.title"),
                    isSelected: vm.showsHardware,
                    action: { vm.showHardware() }
                )

                row(
                    icon: .symbol("square.grid.2x2.fill"),
                    tint: .accentColor,
                    title: L10n.tr("sidebar.appUninstall"),
                    isSelected: vm.showsAppUninstall,
                    isBusy: vm.appUninstall.isLoading,
                    action: { vm.showAppUninstall() }
                )
                .help(L10n.tr("sidebar.appUninstall.help"))

                // The startup-items tool sits below the uninstall row: the
                // two are the housekeeping pair — what to remove, and what
                // to stop from starting in the first place.
                row(
                    icon: .symbol("power"),
                    tint: .accentColor,
                    title: L10n.tr("sidebar.loginItems"),
                    isSelected: vm.showsLoginItems,
                    isBusy: vm.loginItems.isLoading,
                    action: { vm.showLoginItems() }
                )
                .help(L10n.tr("sidebar.loginItems.help"))
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
        // Deliberately no .frame(minWidth:) on the list: the column's width
        // belongs to ContentView's navigationSplitViewColumnWidth, and a list
        // that insists on more width than the column actually gave it renders
        // its overflow clipped at the leading edge — icons and section headers
        // vanish and every title loses its first characters, worst in the
        // longer CJK localizations. The list fills whatever column it gets and
        // the rows truncate at the tail instead, at any width.
    }

    /// Whether the detail area is on the item list rather than on one of the
    /// module pages. Only then may a category row read as selected: the
    /// sidebar has one selected item at a time, and switching pages has to
    /// clear the highlight.
    private var itemListIsActive: Bool {
        !vm.showsSettings && !vm.showsHardware && !vm.showsGeneralCleanup && !vm.showsDiskAnalysis && !vm.showsHomebrew && !vm.showsLargeFiles && !vm.showsAppUninstall && !vm.showsLoginItems
    }

    /// One sidebar row. The row itself — its single-line height, the trailing
    /// figures slot, the selection pill — is `NavRowView`, shared with the
    /// item page's category rail so a row reads the same in either column.
    private func row(
        icon: CategoryIcon.Source,
        tint: Color,
        title: String,
        isSelected: Bool,
        /// Item count and total, for the cleanup rows. The module entries
        /// leave it nil — they report their own totals on their pages.
        figures: (count: Int, size: Int64)? = nil,
        /// A measurement is running in the background (the disk analysis
        /// tool) or a Homebrew query is in flight. Only the running flag is
        /// read, deliberately not the scanned-directory count, which changes
        /// several times a second and would re-render the whole sidebar for
        /// a number the row does not show.
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        NavRowView(
            icon: icon,
            tint: tint,
            title: title,
            isSelected: isSelected,
            figures: figures,
            isBusy: isBusy,
            action: action
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

                // The settings capsule closes the footer on the left, the
                // brand chip signs it off on the right: the storage figures own
                // the top of the block, and the bottom edge carries the app's
                // own entries — settings a destination among them, the brand
                // mark and the share capsule one action away.
                HStack(spacing: 6) {
                    settingsCapsule

                    Spacer(minLength: 0)
                    BrandChip()
                    ShareButton()
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        // The footer is a bottom inset the list scrolls behind, so it needs a
        // backdrop of its own: without one the bottom row reads straight
        // through the footer's figures. The frost is translucent, so on macOS
        // 26+ the sidebar's Liquid Glass keeps showing through it rather than
        // being sawed off as a slab (see SidebarFooterBackdrop).
        .background {
            SidebarFooterBackdrop()
        }
    }

    /// The settings entry at the foot of the sidebar.
    ///
    /// Settings used to be the last row of the list, which made it one more
    /// destination a scroll away. It belongs with the footer's own furniture
    /// instead — the bottom-left corner of the sidebar — because settings
    /// configures Mackit itself rather than anything about the Mac the list
    /// describes.
    ///
    /// The label stays even though the entry is one capsule wide: a bare gear
    /// reads as a display toggle, where the word says what the click opens. At
    /// the sidebar's narrowest the Spacer collapses and the labels truncate,
    /// so the capsules keep their shape instead of pushing each other off the
    /// edge.
    private var settingsCapsule: some View {
        Button {
            vm.showSettings()
        } label: {
            FooterCapsule(isActive: vm.showsSettings) {
                HStack(spacing: 5) {
                    Image(systemName: "gear")
                        .accessibilityHidden(true)

                    Text(verbatim: L10n.tr("sidebar.settings"))
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// The higher the usage ratio, the more alarming the color.
    private var usageTint: Color {
        let fraction = vm.volumeUsage.usedFraction
        if fraction > 0.9 { return .red }
        if fraction > 0.75 { return .orange }
        return .accentColor
    }
}
