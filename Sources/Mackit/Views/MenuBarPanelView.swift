import SwiftUI
import AppKit

/// The panel opened by clicking the menu bar icon.
///
/// Hosted via `MenuBarExtra`'s `.window` style rather than `.menu`: menu content
/// hosted into NSMenu can only render "one icon + one text" — ratio bars,
/// right-aligned values and multi-column layouts are all dropped by SwiftUI
/// (only the first Text of an HStack's subviews survives). For big number cards,
/// monitor values and the app list, a panel is the only way.
///
/// The panel is a persistent view rather than a modal menu, so the VM's
/// real-time state can be read directly here; the poll pushes an update every
/// two seconds, and the panel refreshes along.
struct MenuBarPanelView: View {
    @Environment(AppViewModel.self) private var vm

    private var snapshot: MenuBarSnapshot { vm.menuSnapshot }

    var body: some View {
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
            Divider()
            bottomBar
        }
        .frame(width: panelWidth)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { fitPanelWindow(to: proxy.size.height) }
                    .onChange(of: proxy.size.height) { _, height in
                        fitPanelWindow(to: height)
                    }
            }
        )
    }

    /// Panel width. Same magnitude as Lemon: fits the "name + size" two columns
    /// without taking up half the screen.
    private let panelWidth: CGFloat = 320

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
                    tint: .orange,
                    diameter: 46,
                    symbolSize: 26,
                    symbolWeight: .regular,
                    cornerRadius: 12,
                    fillOpacity: 0.14
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: Formatters.bytes(snapshot.totalSize))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(verbatim: headerSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(verbatim: L10n.tr("panel.clean"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color.green, in: Capsule())
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
                    label: L10n.tr("panel.cpuUsage")
                )
            }
            if vm.showMenuBarMemory {
                bigStat(
                    symbol: "memorychip",
                    value: stats.memoryTotal > 0 ? Formatters.percent(stats.memoryUsedFraction) : "—",
                    label: L10n.tr("panel.memoryUsage")
                )
            }
            if vm.showMenuBarTemperature {
                bigStat(
                    symbol: "thermometer.medium",
                    value: L10n.tr(stats.thermalStateKey),
                    label: L10n.tr("panel.temperature")
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
    }

    private func bigStat(symbol: String, value: String, label: String) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(verbatim: value)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Text(verbatim: label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(verbatim: L10n.tr("panel.memoryUsage"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if snapshot.stats.memoryTotal > 0 {
                Text(verbatim: "\(Formatters.bytes(snapshot.stats.memoryUsed)) / \(Formatters.bytes(snapshot.stats.memoryTotal))")
                    .font(.system(size: 12))
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            Button {
                vm.freeMemory()
                dismissPanel()
            } label: {
                Text(verbatim: L10n.tr("panel.release"))
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
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
                HStack(spacing: 8) {
                    appIcon(for: app)
                        .frame(width: 20, height: 20)
                    Text(verbatim: app.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(verbatim: Formatters.bytes(app.bytes))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }
        }
        .padding(.bottom, 4)
    }

    /// App icon. Falls back to the generic app symbol when unavailable — a
    /// placeholder in the ranking beats an empty gap.
    @ViewBuilder
    private func appIcon(for entry: AppMemoryEntry) -> some View {
        if let image = vm.appIcon(forPath: entry.path) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "app")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        }
    }

    // MARK: - Disk and chart

    /// Disk row: available / total + hardware details entry.
    private var diskRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "internaldrive")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(verbatim: L10n.fmt("panel.diskAvailable", Formatters.bytes(vm.volumeUsage.available)))
                .font(.system(size: 12))
            Text(verbatim: "/ \(Formatters.bytes(vm.volumeUsage.total))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Button {
                vm.showHardwareFromTray()
            } label: {
                Text(verbatim: L10n.tr("panel.hardwareDetail"))
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// CPU usage curve. The data is history accumulated by polling, so the trend
    /// is visible even when the panel is opened.
    private var cpuChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: L10n.tr("panel.cpuHistory"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            CPUHistoryChart(history: snapshot.cpuHistory)
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
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.tr("menubar.settings"))

            Spacer(minLength: 0)

            Button {
                vm.openMainWindowFromTray()
                dismissPanel()
            } label: {
                Text(verbatim: L10n.tr("panel.openMainWindow"))
                    .font(.system(size: 12, weight: .medium))
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
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Adjust the panel window to the content height.
    ///
    /// `MenuBarExtra`'s `.window` style only grows taller, never shorter: when
    /// the content is shorter than last time (an app quitting removes a row from
    /// the ranking, this app disappears from its own list after the main window
    /// closes, monitor switches collapse a whole row), the window keeps its
    /// previous height, the content is centered in the window, leaving a
    /// transparent patch above and below — the desktop shows through behind the
    /// panel, looking like the layout collapsed with blank space hanging behind
    /// the panel. Whenever the content height changes, sync the window frame to
    /// it, pinning the top edge below the menu bar; skip changes smaller than
    /// half a pixel to avoid repeated updates from polling.
    @MainActor
    private func fitPanelWindow(to height: CGFloat) {
        guard height > 0 else { return }
        for window in NSApp.windows
        where String(describing: type(of: window)).hasPrefix("MenuBarExtraWindow") {
            guard abs(window.frame.height - height) > 0.5 else { return }
            var frame = window.frame
            // Keep the top edge fixed: origin.y is the bottom-left corner, so
            // moving the bottom edge up means raising the origin.
            frame.origin.y += frame.height - height
            frame.size.height = height
            window.setFrame(frame, display: true)
            return
        }
    }
}

/// CPU usage curve: line + gradient fill below.
///
/// When there are fewer than one or two data points, draw a flat line — just
/// started and hasn't accumulated enough history yet; an empty coordinate
/// system looks more like "sampling in progress" than a straight line hugging
/// the bottom.
private struct CPUHistoryChart: View {
    let history: [Double]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                if history.count < 2 {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: size.width, height: 1)
                } else {
                    Path { path in
                        for (index, value) in history.enumerated() {
                            let x = size.width * CGFloat(index) / CGFloat(history.count - 1)
                            let y = size.height * (1 - min(1, max(0, value)))
                            let point = CGPoint(x: x, y: y)
                            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                    }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                    Path { path in
                        path.move(to: CGPoint(x: 0, y: size.height))
                        for (index, value) in history.enumerated() {
                            let x = size.width * CGFloat(index) / CGFloat(history.count - 1)
                            let y = size.height * (1 - min(1, max(0, value)))
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                        path.addLine(to: CGPoint(x: size.width, y: size.height))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.25), Color.accentColor.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
        }
    }
}

/// Dismiss the tray panel.
///
/// `MenuBarExtra`'s `.window` style doesn't dismiss itself just because a button
/// was clicked; you have to find that window and close it. `performClose` is a
/// "close request", which this window ignores; only `close()` works. The window
/// class is SwiftUI internal implementation, matched by name prefix — if no match
/// is found, nothing happens; the cost is just the panel staying, which beats
/// closing the wrong window.
@MainActor
func dismissPanel() {
    for window in NSApp.windows where String(describing: type(of: window)).hasPrefix("MenuBarExtraWindow") {
        window.close()
    }
}
