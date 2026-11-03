import SwiftUI

/// Tray agent: a background process resident in the menu bar.
///
/// LSUIElement = 1 (accessory form, see the agent's Info.plist in
/// Scripts/build-app.sh): it never enters the Dock and has no windows. It
/// does only two things—holding the menu bar icon and panel, and running
/// the system monitoring polling; scan / clean / settings / hardware pages
/// are all in the main program, which is woken up by commands sent over
/// via `AppBridge`.
///
/// Why the split matters: closing the main window = the main process
/// quits = the Dock icon disappears, while the monitoring here never stops
/// for a minute. When the user clicks the tray icon, the agent brings the
/// main program up on demand.
///
/// Shares the same binary as the main program, with the role distinguished
/// by bundle ID (see `MackitEntry`).
struct MackitAgentApp: App {
    @State private var vm = AppViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Window style rather than menu style: content hosted into an
        // NSMenu can only render "one icon + a line of text", leaving no
        // room for proportion bars or multi-column layouts.
        //
        // label must be an independent View (MenuBarLabel); vm must not be
        // read inside the inline closure: once the App body depends on
        // menuSnapshot, every snapshot published during a scan forces the
        // App body to re-evaluate—and that cascades into rebuilding the
        // whole view tree (sidebar + the entire table), which in practice
        // dragged scans straight from 10 seconds to 60 seconds with the
        // main thread pegged. After confining the dependency inside
        // MenuBarLabel's own body, only this label redraws.
        MenuBarExtra {
            MenuBarPanelView()
                .environment(vm)
                // The appearance is not applied from here — see
                // `MackitApp`'s Window for why `preferredColorScheme`
                // cannot be taken back to "follow the system". The agent
                // installs the stored choice in
                // `applicationDidFinishLaunching` and re-installs it on the
                // settings-changed broadcast, so the panel this view is
                // hosted in is already tinted by the time it opens.
        } label: {
            // vm must be injected explicitly: the label closure does not
            // inherit the App's environment, so
            // @Environment(AppViewModel.self) inside MenuBarLabel would
            // come up empty.
            MenuBarLabel()
                .environment(vm)
                .onAppear {
                    // The delegate needs to be able to get the VM already
                    // at applicationDidFinishLaunching (to subscribe to
                    // the main program's scan-state broadcast), so it is
                    // installed here.
                    AppDelegate.viewModel = vm
                    // The desktop floating stats window lives only in the
                    // agent process; it is hung on this label, which lives
                    // as long as the process: it installs the VM and
                    // decides show/hide per the current settings.
                    StatsOverlayController.shared.attach(vm)
                }
        }
        .menuBarExtraStyle(.window)
    }
}

/// The label next to the menu bar icon: icon + CPU / memory / temperature.
///
/// "Value on top, short label below, a thin line between groups" is a
/// compact arrangement borrowed from other people's menu bar stats. The
/// whole thing is a single template image rather than a SwiftUI view:
/// macOS 27 testing showed that only the first Text in a MenuBarExtra
/// label renders (a VStack of two Texts, or an HStack of multiple groups,
/// each keeps only the first), so the two-line arrangement can only be
/// drawn into an image—why and how, see `MenuBarStatsImage`.
private struct MenuBarLabel: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        Image(nsImage: MenuBarStatsImage.image(
            metrics: metrics,
            barHeight: menuBarHeight,
            showIcon: vm.showMenuBarLogo
        ))
        // Any change to the master switch or the three monitoring
        // switches re-checks visibility once: settings changed in the main
        // program are broadcast over, and once the agent re-reads and the
        // value changes, the floating window immediately shows / hides.
        .onChange(of: vm.showDesktopStats) { _, _ in StatsOverlayController.shared.sync() }
        .onChange(of: vm.showMenuBarCPU) { _, _ in StatsOverlayController.shared.sync() }
        .onChange(of: vm.showMenuBarMemory) { _, _ in StatsOverlayController.shared.sync() }
        .onChange(of: vm.showMenuBarTemperature) { _, _ in StatsOverlayController.shared.sync() }
    }

    /// The monitoring items in the menu bar. Reads the throttled
    /// snapshot—the label redraws on each snapshot publication, so it must
    /// not read live values (snapshot publication pacing shares the same
    /// gate as scan events).
    private var metrics: [MenuBarStatsImage.Metric] {
        let stats = vm.menuSnapshot.stats
        var result: [MenuBarStatsImage.Metric] = []
        if vm.showMenuBarCPU, let usage = stats.cpuUsage {
            result.append(.init(
                value: Formatters.percent(usage),
                label: L10n.tr("menubar.cpu"),
                alternativeValues: percentWidthBasis
            ))
        }
        if vm.showMenuBarMemory, stats.memoryTotal > 0 {
            result.append(.init(
                value: Formatters.percent(stats.memoryUsedFraction),
                label: L10n.tr("menubar.memory"),
                alternativeValues: percentWidthBasis
            ))
        }
        if vm.showMenuBarTemperature {
            result.append(.init(
                value: stats.temperatureText,
                label: L10n.tr("menubar.temperature"),
                // Both forms the temperature value can take: whole degrees
                // up to three digits, or a thermal-state word on a machine
                // whose sensor table answers nothing. Reserving the widest
                // keeps the menu bar item from jittering as the value
                // switches form.
                alternativeValues: temperatureTexts
            ))
        }
        return result
    }

    /// The widest string a percentage can ever render to, used to fix the
    /// width of the CPU and memory groups.
    ///
    /// `Formatters.percent` clamps to 0–100 and keeps no decimals, so three
    /// digits plus the sign is the longest case there is. A value whose length
    /// changes with every poll (7% → 47% → 100%) would otherwise widen and
    /// narrow the group, dragging the groups after it sideways.
    private let percentWidthBasis = [Formatters.percent(1)]

    /// Every rendering the temperature value can take: whole degrees up to
    /// 110 (the SMC filter's bound — the widest numeric case), plus the four
    /// thermal-state words shown when no numeric reading is available. The
    /// widest of them fixes the group's width, so the menu bar item does not
    /// jitter as the value switches form.
    private var temperatureTexts: [String] {
        ["nominal", "fair", "serious", "critical"]
            .map { L10n.tr("menubar.thermal.\($0)") }
            + [Formatters.degrees(110)]
    }

    /// Menu bar height: the distance between the top of the main screen's
    /// frame and the top of its visible area (regardless of where the Dock
    /// is). Notched machines are about 38pt, unnotched about 22pt—the
    /// two-line font sizes are tiered accordingly.
    private var menuBarHeight: CGFloat {
        guard let screen = NSScreen.main else { return 24 }
        let height = screen.frame.maxY - screen.visibleFrame.maxY
        return height > 0 ? height : 24
    }
}
