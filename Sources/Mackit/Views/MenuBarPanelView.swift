import SwiftUI
import AppKit

/// The panel opened by left-clicking the menu bar icon.
///
/// Hosted in the status-item popover (`TrayStatusController`) rather than in
/// SwiftUI's `MenuBarExtra`: the `.menu` style can only render "one icon +
/// one text" — ratio bars, right-aligned values and multi-column layouts are
/// all dropped by SwiftUI (only the first Text of an HStack's subviews
/// survives) — and `MenuBarExtra` cannot tell the left click that opens this
/// panel from the right click that opens the native context menu. For big
/// number cards, monitor values and the app list, an NSPopover is the only
/// way.
///
/// The panel is a persistent view rather than a modal menu, so the VM's
/// real-time state can be read directly here; the poll pushes an update every
/// two seconds, and the panel refreshes along.
///
/// The overview tab keeps the original single-page content (reclaimable
/// header, monitor row, memory release, app ranking, disk and CPU history);
/// the processor and memory tabs expand it with per-core utilization,
/// composition, swap and process rankings. The tab picker and the bottom
/// action bar are the only shared chrome.
struct MenuBarPanelView: View {
    @Environment(AppViewModel.self) private var vm

    /// The page shown in the panel. Local state: the panel is long-lived, so
    /// the last visited tab survives a close/reopen; the overview is the
    /// starting page.
    @State private var selectedTab: PanelTab = .overview

    private var snapshot: MenuBarSnapshot { vm.menuSnapshot }

    var body: some View {
        VStack(spacing: 0) {
            tabBar

            switch selectedTab {
            case .overview:
                overview
            case .processor:
                ScrollView(.vertical) {
                    ProcessorPage(
                        snapshot: snapshot,
                        cpuName: SystemInfo.cpuName,
                        coreSummary: SystemInfo.coreSummary,
                        uptime: Formatters.uptime(snapshot.stats.uptime),
                        icon: { rank in appIcon(for: rank) },
                        onRangeChange: { range in vm.selectCPUChartRange(range) }
                    )
                }
                .frame(height: detailHeight)
            case .memory:
                ScrollView(.vertical) {
                    MemoryPage(
                        snapshot: snapshot,
                        cpuName: SystemInfo.cpuName,
                        icon: { rank in appIcon(for: rank) },
                        onMetricChange: { metric in vm.selectMemoryChartMetric(metric) }
                    )
                }
                .frame(height: detailHeight)
            }

            Divider()
            bottomBar
        }
        .frame(width: panelWidth)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { fitPanelContent(to: proxy.size) }
                    .onChange(of: proxy.size) { _, size in
                        fitPanelContent(to: size)
                    }
            }
        )
        // An open panel is the exception to the "nobody is watching" sampling
        // guard: its detail pages need monitoring even when every menu-bar
        // toggle is off. The VM checks the popover's visibility on every
        // tick, so a closed panel stops sampling even though this view stays
        // alive.
        .onAppear { vm.beginPanelMonitoring() }
    }

    /// The tab header.
    ///
    /// The selected tab is a folder tab: the tinted band above the page is
    /// cut away around the current tab, so the page surface itself shows
    /// through and the tab merges with the content below it. The band rounds
    /// the page's top corners and the tab's top corners on the same surface;
    /// no divider follows the header because the tab's own fillets already
    /// mark where navigation ends and the page begins.
    private var tabBar: some View {
        PanelTabHeader(selection: $selectedTab)
    }

    /// The panel's original single-page content, unchanged apart from the
    /// bottom bar moving out to the shared chrome.
    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerCard
            sectionDivider

            // System monitor: CPU / memory / temperature. The three switches are
            // each independent; when all are off, the whole row collapses.
            if vm.showMenuBarCPU || vm.showMenuBarMemory || vm.showMenuBarTemperature {
                systemStatsRow
                sectionDivider
            }

            memoryRow
            sectionDivider

            if !snapshot.topApps.isEmpty {
                appMemoryList
                sectionDivider
            }

            diskRow
            sectionDivider
            cpuChart
        }
    }

    /// The detail pages need a bounded height: their content is much taller
    /// than the overview, and the panel popover must stay inside the
    /// visible frame. The overview stays content-sized, as before.
    private var detailHeight: CGFloat {
        guard let screen = NSScreen.main else { return 620 }
        return min(720, max(420, screen.visibleFrame.height - 100))
    }

    /// The app icon for a process group. Daemons have no bundle path and get
    /// the row's generic symbol.
    private func appIcon(for rank: ProcessRank) -> NSImage? {
        guard rank.isApp, !rank.path.isEmpty else { return nil }
        return vm.appIcon(forPath: rank.path)
    }

    /// Panel width: fits the "name + size" two columns and the processor
    /// page's per-core grid without taking up half the screen.
    private let panelWidth: CGFloat = 360

    /// Divider between sections, with left/right padding matching the content's.
    private var sectionDivider: some View {
        Divider().padding(.horizontal, 14)
    }

    // MARK: - Reclaimable space

    /// Header card: icon + reclaimable size + subtitle + clean button.
    ///
    /// The whole card is the button — cleaning is the most important action in
    /// this panel and deserves the largest click area.
    private var headerCard: some View {
        Button {
            vm.cleanFromTray()
            dismissPanel()
        } label: {
            HStack(spacing: 12) {
                IconBadge(
                    // Fall back to an SF Symbol when the brand image is missing,
                    // so an empty badge doesn't appear
                    systemImage: "sparkle.magnifyingglass",
                    image: BrandIcon.image,
                    tint: Theme.Palette.warning,
                    diameter: 46,
                    symbolSize: 26,
                    symbolWeight: .regular,
                    cornerRadius: Theme.Radius.lg,
                    fillOpacity: Theme.Palette.Tint.badge
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: Formatters.bytes(snapshot.totalSize))
                        .font(Theme.Typography.statValueStrong)
                        .monospacedDigit()
                    Text(verbatim: headerSubtitle)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                // The panel's primary action rides the same glass surface as
                // the window's brand CTA: a green-tinted interactive glass
                // capsule on macOS 26+, the flat green pill below that.
                GlassSurface(
                    style: .tinted(Theme.Palette.success),
                    interactive: true,
                    outline: .capsule,
                    fallback: .fill(AnyShapeStyle(Theme.Palette.success))
                ) {
                    Text(verbatim: L10n.tr("panel.clean"))
                        .font(Theme.Typography.subheadlineEmphasis)
                        .foregroundStyle(Theme.Palette.onColor)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Card subtitle: shows the selected amount when there are checkboxes,
    /// otherwise the total.
    private var headerSubtitle: String {
        if snapshot.selectedCount > 0 {
            return L10n.fmt(
                "panel.selected",
                Formatters.bytes(snapshot.selectedSize),
                L10n.items(snapshot.selectedCount)
            )
        }
        return L10n.fmt("panel.reclaimable", L10n.items(snapshot.itemCount))
    }

    // MARK: - System monitor

    /// The three big numbers: CPU usage / memory usage / temperature.
    private var systemStatsRow: some View {
        let stats = snapshot.stats
        return HStack(spacing: 0) {
            if vm.showMenuBarCPU {
                bigStat(
                    symbol: "cpu",
                    value: stats.cpuUsage.map { Formatters.percent($0) } ?? "—",
                    label: L10n.tr("panel.cpuUsage"),
                    widestValue: widestPercent
                )
            }
            if vm.showMenuBarMemory {
                bigStat(
                    symbol: "memorychip",
                    value: stats.memoryTotal > 0 ? Formatters.percent(stats.memoryUsedFraction) : "—",
                    label: L10n.tr("panel.memoryUsage"),
                    widestValue: widestPercent
                )
            }
            if vm.showMenuBarTemperature {
                bigStat(
                    symbol: "thermometer.medium",
                    value: stats.temperatureText,
                    label: L10n.tr("panel.temperature"),
                    valueColor: stats.temperatureIsHot ? Theme.Palette.warning : Color.primary
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
    }

    /// Font of the big numbers. Shared by the visible value and the invisible
    /// width placeholder, so the two measure identically.
    private let bigValueFont = Theme.Typography.statValue

    /// The widest string a percentage can render to.
    ///
    /// `Formatters.percent` clamps to 0–100 and keeps no decimals, so three
    /// digits plus the sign is the longest case there is.
    private let widestPercent = Formatters.percent(1)

    private func bigStat(
        symbol: String,
        value: String,
        label: String,
        widestValue: String? = nil,
        valueColor: Color = .primary
    ) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(.secondary)
                if let widestValue {
                    fixedWidthValue(value, widest: widestValue, color: valueColor)
                } else {
                    Text(verbatim: value)
                        .font(bigValueFont)
                        .monospacedDigit()
                        .foregroundStyle(valueColor)
                }
            }
            Text(verbatim: label)
                .font(Theme.Typography.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// A value text that occupies the width of the widest string it can render
    /// to.
    ///
    /// The monitor values refresh every two seconds, and "9%" → "10%" already
    /// changes the text's width: centered in its cell, the number would slide
    /// sideways every time the digit count changes. An invisible copy of the
    /// widest value holds the layout width — `.hidden()` also drops it from
    /// accessibility, so VoiceOver reads only the real value — and the real
    /// value is drawn over it at the leading edge, which keeps the digits on
    /// one grid anchored right after the icon.
    private func fixedWidthValue(_ value: String, widest: String, color: Color) -> some View {
        Text(verbatim: widest)
            .font(bigValueFont)
            .monospacedDigit()
            .hidden()
            .overlay(alignment: .leading) {
                Text(verbatim: value)
                    .font(bigValueFont)
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
    }

    // MARK: - Memory

    /// Memory row: absolute usage + the "Free" entry.
    ///
    /// The ratio is already in the monitor row above; this shows absolute usage
    /// instead — the same space carries another dimension of information, not
    /// repeating 63% verbatim. This row always shows: the ratio can be turned
    /// off, but the free-memory action shouldn't disappear along with it.
    private var memoryRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "memorychip")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(verbatim: L10n.tr("panel.memoryUsage"))
                .font(Theme.Typography.subheadline)
                .foregroundStyle(.secondary)

            if snapshot.stats.memoryTotal > 0 {
                // The total is a capacity, so it uses the same rounded
                // `memory` format as the memory page; `bytes` would print
                // 17.18 GB for a 16 GB machine.
                Text(verbatim: "\(Formatters.bytes(snapshot.stats.memoryUsed)) / \(Formatters.memory(snapshot.stats.memoryTotal))")
                    .font(Theme.Typography.subheadline)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            Button {
                vm.freeMemory()
                dismissPanel()
            } label: {
                Text(verbatim: L10n.tr("panel.release"))
                    .font(Theme.Typography.subheadlineMedium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Palette.link)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Memory usage ranking: icon + name + size.
    private var appMemoryList: some View {
        VStack(spacing: 0) {
            ForEach(Array(snapshot.topApps.enumerated()), id: \.element.id) { index, app in
                if index > 0 {
                    Divider()
                        .padding(.leading, 42)
                }
                AppMemoryRow(
                    entry: app,
                    icon: vm.appIcon(forPath: app.path)
                ) { entry in
                    vm.quitApp(entry)
                }
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Disk and chart

    /// Disk row: available / total + hardware details entry.
    private var diskRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "internaldrive")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(verbatim: L10n.fmt("panel.diskAvailable", Formatters.bytes(vm.volumeUsage.available)))
                .font(Theme.Typography.subheadline)
            Text(verbatim: "/ \(Formatters.bytes(vm.volumeUsage.total))")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Button {
                vm.showHardwareFromTray()
            } label: {
                Text(verbatim: L10n.tr("panel.hardwareDetail"))
                    .font(Theme.Typography.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Palette.link)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// CPU usage curve. The data is history accumulated by polling, so the trend
    /// is visible even when the panel is opened.
    private var cpuChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: L10n.tr("panel.cpuHistory"))
                .font(Theme.Typography.footnote)
                .foregroundStyle(.secondary)
            UsageLineChart(values: snapshot.cpuHistory)
                .frame(height: 56)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Bottom action bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                vm.openSettingsFromTray()
                dismissPanel()
            } label: {
                Image(systemName: "gear")
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.tr("menubar.settings"))

            // The detail pages have no header card, so the one-click clean
            // rides the shared bottom bar; the overview keeps its full card.
            Button {
                vm.cleanFromTray()
                dismissPanel()
            } label: {
                Image(systemName: "wand.and.stars")
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.tr("panel.clean"))

            Spacer(minLength: 0)

            Button {
                vm.openMainWindowFromTray()
                dismissPanel()
            } label: {
                Text(verbatim: L10n.tr("panel.openMainWindow"))
                    .font(Theme.Typography.subheadlineMedium)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Spacer(minLength: 0)

            Menu {
                Button(role: .destructive) {
                    vm.quitFromTray()
                } label: {
                    Text(verbatim: L10n.tr("menubar.quit"))
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Sync the popover's content size to the panel's measured size.
    ///
    /// The panel draws from the popover's `contentSize`, and NSPopover does
    /// not track SwiftUI's fitting size while it is open: when the content
    /// height changes (an app quitting removes a row from the ranking, this
    /// app disappears from its own list after the main window closes, the
    /// monitor switches collapse a whole row), the popover would keep its
    /// previous height and either leave a transparent blank patch behind the
    /// panel or clip the content. Every measurement is pushed into the
    /// controller, which skips sub-half-pixel changes so the two-second
    /// polling does not keep resetting the size.
    @MainActor
    private func fitPanelContent(to size: CGSize) {
        TrayStatusController.current?.panelContentSizeChanged(size)
    }
}

/// One row of the memory ranking: icon + name + memory usage.
///
/// The two hover controls — the quit button and the warning beside it — take
/// the place of the size text rather than sitting beside it: the row keeps one
/// width, so hovering neither pushes the name aside nor grows the panel (whose
/// height is synced to its content, see `fitPanelContent`).
private struct AppMemoryRow: View {
    let entry: AppMemoryEntry
    /// The app's icon, nil when it could not be read.
    let icon: NSImage?
    let onQuit: (AppMemoryEntry) -> Void

    /// Hover is tracked on the row and on the controls separately, then OR-ed
    /// together: a control sitting on top of a row can take the pointer's
    /// tracking over from it, and the controls would blink out from under the
    /// pointer on their way to being clicked.
    @State private var isRowHovered = false
    @State private var isControlsHovered = false

    private var isHovered: Bool { isRowHovered || isControlsHovered }

    var body: some View {
        HStack(spacing: 8) {
            iconView
                .frame(width: 20, height: 20)
            Text(verbatim: entry.name)
                .font(Theme.Typography.subheadline)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(verbatim: Formatters.bytes(entry.bytes))
                .font(Theme.Typography.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .opacity(isHovered ? 0 : 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        // The highlight says which row the two hover controls belong to — the
        // rows are only a few points tall, and the pointer is already inside
        // one of them by the time the controls fade in.
        .background(isHovered ? Theme.Palette.surfaceHover : Color.clear)
        .onHover { isRowHovered = $0 }
        .animation(.easeOut(duration: Theme.Motion.stateChange), value: isHovered)
        .overlay(alignment: .trailing) {
            HStack(spacing: 6) {
                quitButton
                quitWarning
            }
            // Line the controls up with the size text they take the place of:
            // the overlay aligns to the row's outer edge, which is 14pt wider
            // than the content inside it.
            .padding(.trailing, 14)
            .opacity(isHovered ? 1 : 0)
            .onHover { isControlsHovered = $0 }
            // The warning hangs off the controls' leading edge, in the space the
            // size text vacates, rather than floating over the row above — the
            // rows are dense enough that a bubble up there buries the
            // neighbour's figures. It rides on the controls' own overlay so
            // that the controls' bounds, and with them the tracking area that
            // drives the hover, never change size.
            .overlay(alignment: .leading) {
                if isControlsHovered {
                    quitHint
                        .offset(x: -(hintWidth + 6))
                        .transition(.opacity)
                        .animation(.easeOut(duration: Theme.Motion.stateChange), value: isControlsHovered)
                }
            }
        }
    }

    /// The warning's width: 210pt of text plus 8pt of padding each side. It is
    /// placed by offset from the controls' leading edge, so the offset is
    /// derived from this rather than measured at runtime.
    private let hintWidth: CGFloat = 226

    /// App icon. Falls back to the generic app symbol when unavailable — a
    /// placeholder in the ranking beats an empty gap.
    @ViewBuilder
    private var iconView: some View {
        if let image = icon {
            Image(nsImage: image)
                .resizable()
        } else {
            Image(systemName: "app")
                .font(Theme.Typography.body)
                .foregroundStyle(.secondary)
        }
    }

    private var quitButton: some View {
        Button {
            onQuit(entry)
        } label: {
            Text(verbatim: L10n.tr("panel.quitApp"))
                .font(Theme.Typography.subheadlineMedium)
                .foregroundStyle(Theme.Palette.link)
        }
        .buttonStyle(.plain)
        // The controls stay in the layout and in hit testing whether they are
        // visible or not: taking them out re-installs the row's tracking area,
        // which AppKit reports as the pointer having left the row, and the
        // controls would blink out from under the pointer. Disabling them
        // keeps the invisible ones inert instead — the row has no click action
        // of its own to shadow.
        .disabled(!isHovered)
        .accessibilityLabel(L10n.fmt("panel.quitApp.help", entry.name))
    }

    /// The warning that accompanies the quit button.
    ///
    /// Quitting is the one action in the ranking that can cost the user work
    /// in another app, so its consequence is spelled out right where the
    /// button is. It is a marker rather than a second button: nothing happens
    /// when it is clicked, and the warning next to it is what carries the
    /// message (see `quitHint`).
    private var quitWarning: some View {
        Image(systemName: "info.circle")
            .font(Theme.Typography.body)
            .foregroundStyle(.secondary)
            .accessibilityLabel(L10n.tr("panel.quitApp.warning"))
    }

    /// The warning shown the instant the pointer reaches the controls.
    ///
    /// Deliberately not AppKit's tooltip: `.help` only appears after the
    /// pointer has rested on the control for a while, which is far too slow
    /// for something the user is meant to read before clicking.
    ///
    /// The width is exact rather than a maximum — a Text given only a maxWidth
    /// truncates instead of wrapping — and the height is exact too: inside an
    /// overlay the text is offered the row's height, and without a definite
    /// height of its own it lays out on one line and clips. Both together keep
    /// the bubble the same size whatever the language.
    ///
    /// It covers the app name while it shows. A row's content is only 292pt
    /// wide and the warning needs most of it, so there is no room for both;
    /// the name returns the moment the pointer leaves the controls.
    private var quitHint: some View {
        GlassSurface(
            outline: .rounded(cornerRadius: Theme.Radius.sm),
            fallback: .material(.ultraThinMaterial),
            fallbackHairline: (color: Theme.Palette.hairline, width: Theme.Elevation.hairlineWidth),
            fallbackShadow: Theme.Elevation.panel
        ) {
            Text(verbatim: L10n.tr("panel.quitApp.warning"))
                .font(Theme.Typography.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 210, height: 26, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
        }
        .allowsHitTesting(false)
    }
}

/// Dismiss the tray panel.
///
/// The panel lives in the status-item popover (`TrayStatusController`); a
/// transient popover already closes on any outside click, but the buttons
/// that change windows — open main window, settings, clean — close it
/// explicitly, so the panel never lingers over a window that just came to
/// the front.
@MainActor
func dismissPanel() {
    TrayStatusController.current?.closePanel()
}
