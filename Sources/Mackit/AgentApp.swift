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
        Image(nsImage: MenuBarStatsImage.image(metrics: metrics, barHeight: menuBarHeight))
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
            result.append(.init(value: Formatters.percent(usage), label: L10n.tr("menubar.cpu")))
        }
        if vm.showMenuBarMemory, stats.memoryTotal > 0 {
            result.append(.init(
                value: Formatters.percent(stats.memoryUsedFraction),
                label: L10n.tr("menubar.memory")
            ))
        }
        if vm.showMenuBarTemperature {
            result.append(.init(
                value: L10n.tr(stats.thermalStateKey),
                label: L10n.tr("menubar.temperature"),
                // The width of the thermal-state word varies with the
                // state (Normal ↔ Critical), so space is reserved for the
                // widest of the four values; the menu bar item does not
                // jitter when switching
                alternativeValues: thermalStateTexts
            ))
        }
        return result
    }

    /// The four thermal-state values, used to fix the width of the
    /// temperature group.
    private var thermalStateTexts: [String] {
        ["nominal", "fair", "serious", "critical"]
            .map { L10n.tr("menubar.thermal.\($0)") }
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
