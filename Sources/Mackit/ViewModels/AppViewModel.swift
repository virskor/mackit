import SwiftUI
import AppKit

@MainActor
@Observable
final class AppViewModel {
    // MARK: State

    // rawValue is for IPC use: scan state has to be serialized before
    // being broadcast to the tray agent, since the enum itself is not
    // visible between the two processes and a string is the most robust
    // wire format.
    enum ScanPhase: String, Equatable {
        case idle
        case scanning
        case done
    }

    enum CleanPhase: String, Equatable {
        case idle
        case confirming
        case cleaning
        case done
    }

    var phase: ScanPhase = .idle
    var cleanPhase: CleanPhase = .idle

    /// All discovered items, appended in discovery order.
    private(set) var items: [JunkItem] = []
    /// Scan progress description.
    var progressLabel: String = ""
    var progressFraction: Double = 0

    /// The category selected in the sidebar; nil means all.
    var selectedCategory: JunkCategory? = nil
    /// The general cleanup page is selected in the sidebar: the detail area
    /// switches to the Lemon-style general module and no longer shows the
    /// developer cleanup content.
    var showsGeneralCleanup: Bool = false
    /// Which cleanup feature the main window is currently showing. Only
    /// affects what the window browses and cleans; the tray panel always
    /// reports both features combined, and its one-click clean sweeps
    /// everything safe.
    var cleanupScope: CleanupScope {
        showsGeneralCleanup ? .general : .developer
    }

    /// The mode a pending confirmation will clean, nil meaning every mode
    /// (the tray one-click path). Set when entering `.confirming`.
    private var pendingCleanScope: CleanupScope? = nil
    var searchText: String = ""
    /// Current sort: field + direction. Header clicks rewrite this value
    /// directly via SwiftUI, while the toolbar menu writes an `ItemSort`
    /// preset; the two share one set of comparators, so there is no
    /// divergence such as "the menu picks natural order but the header
    /// click yields lexicographic order".
    var sortComparator: JunkItemComparator = ItemSort.sizeDescending.comparator
    /// Whether to show only safe items.
    var safeOnly: Bool = false
    /// The settings row is selected in the sidebar: the detail area
    /// switches to an embedded settings page and no longer shows cleanup
    /// item content. Settings does not open a separate window; this is
    /// the standard Mac app (sidebar navigation + detail area) approach.
    var showsSettings: Bool = false
    /// The hardware detection row is selected in the sidebar: the detail
    /// area switches to the hardware info page, using the same container
    /// as the settings page.
    var showsHardware: Bool = false
    /// The disk analysis tool row is selected in the sidebar: the detail
    /// area switches to the analysis page, the same embedded-page pattern
    /// as the hardware page.
    var showsDiskAnalysis: Bool = false
    /// The Homebrew manager tool row is selected in the sidebar: the detail
    /// area switches to the manager page, same embedded-page pattern again.
    var showsHomebrew: Bool = false
    /// The app uninstall tool row is selected in the sidebar: the detail
    /// area switches to the uninstall page, same embedded-page pattern again.
    /// Apps are no longer part of the cleanup scan — uninstalling is its own
    /// tool, and this flag is what shows it.
    var showsAppUninstall: Bool = false
    /// The large-file analysis tool row is selected in the sidebar: the
    /// detail area switches to the analysis page, the same embedded-page
    /// pattern as the other tools. This one answers "which individual files
    /// are taking up the space", where the disk analysis answers it by
    /// directory tree.
    var showsLargeFiles: Bool = false

    /// Row selection set, consistent with the list checkmarks. All of the
    /// state and every rule that decides it live in `CleanupSelection`; this
    /// is the item-id view of it the list and the tray panel read.
    var selection: Set<String> {
        get { selectionState.ids }
        set { selectionState.replace(with: newValue) }
    }

    /// The one owner of the selection: what a scan pre-checks, what a toggle
    /// moves, what a clean leaves behind, what gets remembered.
    private let selectionState = CleanupSelection()

    /// State model of the disk analysis tool page. Lives for the whole
    /// session so its tree — and the measurement still producing it — survives
    /// page switches. Injectable so a test can drive the page-switch contract
    /// against a fixture tree instead of the real disk.
    let diskAnalysis: DiskAnalysisModel

    /// State model of the Homebrew manager tool page. Same session-lifetime
    /// and injectability contract as `diskAnalysis`: the snapshot survives
    /// page switches, and tests drive the page against fake inspections.
    let homebrew: HomebrewModel

    /// State model of the app uninstall tool page. Same session-lifetime and
    /// injectability contract as `diskAnalysis` and `homebrew`: the scanned
    /// app list survives page switches, and tests drive the page against
    /// fixture apps.
    let appUninstall: AppUninstallModel

    /// State model of the large-file analysis tool page. Same session-lifetime
    /// and injectability contract as the other tools: the walked file list
    /// survives page switches, and tests drive the page against a fixture
    /// walk instead of the real disk.
    let largeFiles: LargeFilesModel

    /// State model of the crash log list shown in the settings page. Same
    /// injectability contract as the tool models: the settings section lists
    /// whatever store this holds, so tests drive it against fixture records
    /// instead of the real Application Support folder.
    let crashLogs: CrashLogsModel

    /// Cleanup result summary.
    var lastReclaimed: Int64 = 0
    var lastFailures: Int = 0
    var cleanOutcomes: [CleanOutcome] = []
    var cleanCurrentTitle: String = ""
    var cleanProgress: Double = 0

    /// Whether the clean that just finished put anything into a Trash. Those
    /// bytes are not back on the volume yet — the summary says "moved out"
    /// rather than claiming them as released.
    var lastCleanMovedToTrash: Bool {
        cleanOutcomes.contains { $0.movedToTrash }
    }

    /// State snapshot consumed by the menu bar panel. See
    /// `publishMenuSnapshot`.
    private(set) var menuSnapshot = MenuBarSnapshot()
    /// The currently shown operation hint (Toast); nil means no hint.
    var banner: Banner?
    /// The timer task that auto-dismisses the Toast; a new hint cancels
    /// the previous one.
    private var bannerDismissTask: Task<Void, Never>?
    var volumeUsage: VolumeUsage = .home()

    // MARK: Settings

    var autoSelectRisk: AutoSelectLevel = .none
    var moveToTrash: Bool = true
    var includeCLI: Bool = true
    /// The general cleanup rows the user asked to remember, checked
    /// automatically on every later scan. nil means "not set yet" and falls
    /// back to the built-in default (the rows the layout pre-checks:
    /// safe and review, minus the opt-in language row).
    var generalSelectedRows: Set<String>? {
        get { selectionState.rememberedRows }
        set { selectionState.rememberedRows = newValue }
    }
    /// Whether the regenerable junk installed apps leave behind (caches,
    /// HTTP storages, WebKit data, logs, crash reports) is enumerated in
    /// the main scan, feeding the general module's app-junk row. The apps
    /// themselves are not part of the scan — uninstalling them is the app
    /// uninstall tool's job.
    var includeApps: Bool = true
    /// Whether either process writes a crash record when it dies on a fatal
    /// signal or an uncaught exception (see `CrashCollector`). On by default:
    /// the record is a few hundred bytes in Application Support, and the one
    /// time it matters is the one time nobody could have turned it on first.
    /// Turning it off stops future writes and keeps the records already
    /// collected.
    var collectCrashLogs: Bool = true
    var projectRoots: [String] = []
    /// Whether the app is registered to launch at login — the user's choice,
    /// persisted in shared settings. The system registration is reconciled
    /// against this (see `LaunchAtLogin.repairIfNeeded`), never trusted as the
    /// source of truth: a registration the system gave up on reads as off even
    /// though the user asked for it.
    ///
    /// What the login item registers is the tray agent rather than the
    /// main app: at login only the menu bar icon appears, and the main
    /// window waits for the user to click the tray (see `LaunchAtLogin`).
    var launchAtLogin: Bool = false
    /// Toggles for the tray menu's monitoring section, each taking effect
    /// individually; the whole block collapses when all are off.
    var showMenuBarCPU: Bool = true
    var showMenuBarMemory: Bool = true
    var showMenuBarTemperature: Bool = true
    /// Whether the brand icon is drawn in front of the monitoring values in
    /// the menu bar item. On by default: the icon is what makes the item
    /// recognizable at a glance.
    ///
    /// Only dropped when at least one monitoring value is showing — with the
    /// icon off and all three values off as well, the item would be an empty
    /// image and the app would vanish from the menu bar with no way back
    /// (see `MenuBarStatsImage`).
    var showMenuBarLogo: Bool = true
    /// Master toggle for the desktop floating stats window. Off by
    /// default: a permanently present block on the desktop is a
    /// conspicuous change, so the user should turn it on themselves;
    /// which items are shown follows the three monitoring toggles above,
    /// and the position is persisted separately (only the agent writes
    /// it, see `OverlayPositionStore`).
    var showDesktopStats: Bool = false

    /// Whether the floating window should be shown at this moment: the
    /// master toggle is on, and at least one monitoring toggle is on.
    /// With all three off the floating window would be empty, so better to
    /// collapse it.
    var statsOverlayVisible: Bool {
        showDesktopStats && (showMenuBarCPU || showMenuBarMemory || showMenuBarTemperature)
    }

    /// Static info shown on the hardware page. Sampled once when entering
    /// the page (see `showHardware`), and not refreshed along with the
    /// system stats polling — these are all values that stop changing
    /// once installed.
    private(set) var hardwareProfile: HardwareProfile = HardwareProfile()

    /// The most recent system stats sample. The tray menu reads the copy
    /// in the snapshot; a copy is kept here to take a baseline when
    /// freeing memory.
    private(set) var stats: SystemStats = SystemStats()
    /// The few apps using the most memory; the panel's ranking reads the
    /// copy in the snapshot.
    private(set) var topApps: [AppMemoryEntry] = []
    /// CPU usage history, newest last. The panel's graph reads the copy in
    /// the snapshot.
    private(set) var cpuHistory: [Double] = []

    // MARK: Dependencies

    private var scanTask: Task<Void, Never>?
    private var cleanTask: Task<Void, Never>?
    /// System stats polling task. See `startStatsPolling`.
    private var statsTask: Task<Void, Never>?
    /// A stateful sampler: CPU usage needs the difference between two
    /// adjacent samples.
    private var statsSampler = SystemStatsSampler()

    /// The start moment of scan / clean, used to record duration in logs.
    private var scanStartedAt: ContinuousClock.Instant?
    private var cleanStartedAt: ContinuousClock.Instant?

    /// System stats sampling interval.
    ///
    /// The tray panel only reads the snapshot when opened, so this cadence
    /// only determines "how fresh the numbers are at the moment the panel
    /// is opened"; each sample is just a few system calls, so the cost is
    /// negligible.
    private let statsPollInterval: Duration = .seconds(2)

    /// How many sample points the CPU history retains. One point every
    /// two seconds; 60 points is the last two minutes.
    static let cpuHistoryCapacity = 60

    /// The minimum publishing interval for the menu snapshot.
    ///
    /// The scan advances on a per-work-unit cadence; exposing these
    /// changes directly to MenuBarExtra would make the menu items hosted
    /// in an NSMenu rebuild dozens of times per second — the menu would
    /// flicker continuously when open. The menu instead depends only on a
    /// downsampled snapshot, while the main window still reads live
    /// values.
    private let menuPublishInterval: Duration = .milliseconds(200)
    private var lastMenuPublish: ContinuousClock.Instant?

    /// The nesting depth of NSMenus currently tracking the mouse.
    ///
    /// The tray menu, main menu bar menu, and contextual menu all go
    /// through here. While a menu is open the main thread is entirely
    /// stuck in AppKit's modal tracking loop, so scan events cannot get
    /// through at all; but menu item actions execute inside the tracking
    /// loop (clicking "Rescan" or a toggle), and at that moment the main
    /// thread is alive — publishing a snapshot then would re-host the
    /// whole NSMenu, interrupting AppKit's mouse tracking: the highlight
    /// resets, the row under the pointer is swapped out, and no row can
    /// be selected by moving the mouse into it. Therefore publishing is
    /// always suspended for the whole duration of tracking.
    private var menuTrackingDepth = 0
    /// The moment tracking was first entered, used for the
    /// `maxMenuFreeze` fallback.
    private var menuTrackingSince: ContinuousClock.Instant?

    /// Fallback duration in case a tracking "end" notification is missed.
    ///
    /// Missing a single end notification would freeze the snapshot
    /// permanently, and the tray menu would show stale numbers from then
    /// on. Once this duration is exceeded, treat tracking as ended and
    /// resume publishing: the cost is one extra rebuild for a menu that
    /// stayed open too long, which beats freezing forever. Can be lowered
    /// in tests to verify this path.
    var maxMenuFreeze: Duration = .seconds(30)

    /// When a "clean" command arrives from the tray while the main app is
    /// still scanning (or has never scanned at all): note it down, and
    /// after the scan finishes, add "select safe items + enter
    /// confirmation".
    private var pendingCleanAfterScan = false

    /// `statsPolling` can be turned off for tests: background polling
    /// publishes snapshots on its own cadence, disrupting the timing of
    /// "emit one event, assert one snapshot" in tests. Visible within the
    /// module so tests can drive it directly; the default value is the
    /// app's startup behavior.
    init(statsPolling: Bool = true, diskAnalysis: DiskAnalysisModel = DiskAnalysisModel(), homebrew: HomebrewModel = HomebrewModel(), appUninstall: AppUninstallModel = AppUninstallModel(), largeFiles: LargeFilesModel = LargeFilesModel(), crashLogs: CrashLogsModel = CrashLogsModel()) {
        self.diskAnalysis = diskAnalysis
        self.homebrew = homebrew
        self.appUninstall = appUninstall
        self.largeFiles = largeFiles
        self.crashLogs = crashLogs
        // A remembered row selection is the one piece of selection state that
        // outlives a process, so the model's user actions route through here
        // to persist it. `loadSettings` below assigns the stored value
        // directly and does not trigger a write.
        selectionState.onRememberedRowsChanged = { [weak self] _ in
            self?.saveSettings()
        }
        loadSettings()
        if statsPolling { startStatsPolling() }
        // NSMenu's tracking notifications are delivered by AppKit on the
        // main thread, so handling is therefore on the main thread too.
        // selector registration needs no token to be held, and
        // NotificationCenter weakly references selector observers, so no
        // dangling pointer remains after the object is deallocated.
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuDidBeginTracking),
            name: NSMenu.didBeginTrackingNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuDidEndTracking),
            name: NSMenu.didEndTrackingNotification, object: nil
        )
    }

    /// A menu has begun tracking the mouse (including submenus, hence a
    /// depth counter rather than a boolean). Visible within the module so
    /// tests can drive it directly.
    @objc func menuDidBeginTracking() {
        if menuTrackingDepth == 0 { menuTrackingSince = ContinuousClock.now }
        menuTrackingDepth += 1
    }

    @objc func menuDidEndTracking() {
        guard menuTrackingDepth > 0 else { return }
        menuTrackingDepth -= 1
        guard menuTrackingDepth == 0 else { return }
        menuTrackingSince = nil
        // Flush the changes accumulated during tracking now: the moment
        // the menu closes it catches up with the latest state
        publishMenuSnapshot(force: true)
    }

    // MARK: - Menu Bar Snapshot

    /// Packs the current state into one snapshot for the menu bar panel.
    ///
    /// `force` is used for phase transitions and explicit user actions
    /// (checking, cleaning, deleting), which must be reflected in the menu
    /// immediately; progress and discovery events during a scan are
    /// instead downsampled at `menuPublishInterval`, and when the content
    /// has not changed, not even a notification is sent.
    ///
    /// Each half of the snapshot has its own owner: both processes write
    /// the monitoring fields (stats / topApps / cpuHistory) from their own
    /// sampling; only the main app writes the scan / clean fields, and the
    /// agent process publishes only the monitoring half (see
    /// `isAgentProcess`). Visible within the module so tests can drive it
    /// directly.
    func publishMenuSnapshot(force: Bool = false) {
        let now = ContinuousClock.now

        // Never publish while a menu is open. Every rebuild of a menu item
        // hosted in an NSMenu resets AppKit's mouse tracking once: the
        // highlight jumps away, the row under the pointer is swapped out,
        // and no row can be selected by moving the mouse into it. During a
        // scan the snapshot refreshes at 200ms, rebuilding repeatedly at
        // exactly this cadence, so not a single publish happens for the
        // whole duration of tracking.
        if menuTrackingDepth > 0 {
            if let since = menuTrackingSince, now - since < maxMenuFreeze { return }
            // Fallback: in case "tracking ended" was missed, the freeze
            // must not become permanent. By now there is most likely no
            // menu open, so clear the last publish time and flush one
            // immediately; if the menu is in fact still open, the cost is
            // one extra rebuild, which beats the tray menu showing stale
            // numbers forever.
            menuTrackingDepth = 0
            menuTrackingSince = nil
            lastMenuPublish = nil
        } else if !force, let last = lastMenuPublish, now - last < menuPublishInterval {
            return
        }
        lastMenuPublish = now

        // The monitoring fields are computed live from local sampling on
        // both sides; the scan / clean fields are only computed by the
        // main app. The agent's local VM is always empty (the scan runs on
        // the main app's side), so writing from local values here would
        // wipe the numbers that applyRemoteScanState just merged in back
        // to 0 — the panel would flash "0 B / 0 items" every two seconds
        // during a scan (the agent's polling cadence).
        var next = menuSnapshot
        if !isAgentProcess {
            next.phase = phase
            next.cleanPhase = cleanPhase
            next.percent = Int((max(0, min(1, progressFraction)) * 100).rounded())
            next.totalSize = totalSize
            next.itemCount = items.count
            next.selectedCount = selection.count
            next.selectedSize = selectedSize
        }
        next.stats = stats
        next.topApps = topApps
        next.cpuHistory = cpuHistory
        if next != menuSnapshot {
            menuSnapshot = next
            // Broadcast the scan / clean state to the tray agent so the
            // panel header shows the reclaimable size and selection count.
            // Only the main app sends it: the agent's VM reaches this
            // point too, and letting it send as well would turn into the
            // two processes forwarding to each other. When the content
            // has not changed, do not send, saving pointless
            // inter-process traffic.
            if isMainApp {
                AppBridge.postScanState(scanStateSnapshot())
            }
        }
    }

    /// Whether the current process is the main app. The agent's VM does
    /// not broadcast state outward (see `publishMenuSnapshot`).
    private var isMainApp: Bool {
        Bundle.main.bundleIdentifier == AppIdentity.mainBundleID
    }

    /// Whether the current process is the tray agent.
    ///
    /// The snapshot's scan / clean fields are read-only in the agent
    /// process: the local VM never scans, and those numbers are broadcast
    /// by the main app and merged in by `applyRemoteScanState`. Publishing
    /// accordingly skips this half — otherwise the agent's own monitoring
    /// polling (once every two seconds) and the menu toggle flush would
    /// both wipe it to 0 with local empty values, and the panel would
    /// flash "0 B / 0 items" repeatedly during a scan. Can be set to true
    /// in tests to verify the agent-side merge path.
    var isAgentProcess: Bool = AppIdentity.currentProcessIsAgent

    // MARK: - System Stats Polling

    /// Starts system stats polling: sample once first, then once every two
    /// seconds.
    ///
    /// With all three toggles off the sampling task stays alive but skips
    /// straight through each time it wakes — a sleeping task consumes no
    /// CPU, whereas adding/removing the task per toggle would leave one
    /// more state path to maintain.
    func startStatsPolling() {
        guard statsTask == nil else { return }
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                // Once the ViewModel is deallocated the task ends too,
                // leaving no idling loop behind
                guard let self else { return }
                sampleSystemStats()
                try? await Task.sleep(for: statsPollInterval)
            }
        }
    }

    /// Samples system stats once and publishes a snapshot. Visible within
    /// the module so tests can drive it directly.
    func sampleSystemStats() {
        // Do not sample when nobody is watching: sampling triggers a
        // snapshot publish, and publishing makes the whole panel recompute
        // its layout once.
        guard showMenuBarCPU || showMenuBarMemory || showMenuBarTemperature else { return }
        refreshStats()
    }

    /// Unconditionally refreshes a system stats sample once.
    private func refreshStats() {
        stats = statsSampler.sample()
        // The CPU history only records samples that got a usage reading:
        // if sampling fails, stuffing a nil in would add a spurious
        // bottom-hugging kink to the graph.
        if let usage = stats.cpuUsage {
            cpuHistory.append(usage)
            if cpuHistory.count > Self.cpuHistoryCapacity { cpuHistory.removeFirst() }
        }
        // App memory is independent of the monitoring toggles: the ranking
        // is permanent content of the cleanup panel, so turning off the
        // CPU display should not also make "who is eating memory"
        // disappear.
        topApps = AppMemorySampler.topApps()
        publishMenuSnapshot(force: true)
    }

    /// Tray "Clean": the whole card is this button, meant to work
    /// "without having to open the main window first either". The agent
    /// side only sends the command to the main app; checking and
    /// confirmation both happen there.
    func cleanFromTray() {
        AppBridge.send(.clean)
    }

    /// Panel action: open the main window. Window rebuilding is handled by
    /// the main app's IPC handler (the main window is a `Window` singleton
    /// scene, and `openWindow` works for both "already exists" and
    /// "closed": the former focuses, the latter rebuilds. Switching to
    /// WindowGroup would open a new window every time; see the scene
    /// comment in MackitApp).
    func openMainWindowFromTray() {
        AppBridge.send(.openMainWindow)
    }

    /// Panel action: open the settings page (embedded in the main window).
    func openSettingsFromTray() {
        AppBridge.send(.settings)
    }

    /// Panel action: open the hardware details page (embedded in the main
    /// window).
    func showHardwareFromTray() {
        AppBridge.send(.hardware)
    }

    /// Panel action: quit. Broadcast the command to the main app first (it
    /// may have a window open), then quit ourselves.
    ///
    /// Distributed notifications are delivered asynchronously, and an
    /// immediately following terminate may cut off a notification before
    /// it has left the process; move quitting to the next runloop turn.
    func quitFromTray() {
        AppBridge.send(.quit)
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    /// Panel action: quit one of the apps in the memory ranking (the button
    /// that appears on a row while hovered).
    ///
    /// The panel stays open afterwards — quitting several apps in a row is
    /// the point of the button, and the ranking refreshes right away so the
    /// row disappears under the pointer.
    func quitApp(_ entry: AppMemoryEntry) {
        let outcome = AppQuitter().quit(pid: entry.pid, expectedPath: entry.path) { [weak self] in
            self?.quitFromTray()
        }
        switch outcome {
        case .quittingMackit:
            MackitLog.system.info("quit app: matched Mackit itself, quitting the whole app instead")
        case .alreadyGone:
            MackitLog.system.info("quit app failed: \(entry.name, privacy: .public) process no longer exists")
        case .quitRequested:
            MackitLog.system.info("quit app: \(entry.name, privacy: .public)")
        }
        refreshStats()
    }

    // MARK: - Main App Side Command Handling (IPC)

    /// Where the main app goes after receiving a `.clean` command.
    ///
    /// Three paths: the main window has already scanned (check safe items
    /// directly and enter confirmation); scanning in progress (wait for
    /// the scan to finish, then follow up); never scanned (start a scan
    /// first, then follow up). The last one cannot simply be checked off
    /// — the list is still empty, and the confirmation panel would pop up
    /// empty.
    func cleanFromRemote() {
        switch phase {
        case .scanning:
            pendingCleanAfterScan = true
        case .idle where items.isEmpty:
            pendingCleanAfterScan = true
            startScan()
        default:
            beginCleanFromRemote()
        }
    }

    /// Check all safe items and enter confirmation. When the selection is
    /// non-empty, keep the user's current selection, consistent with the
    /// semantics of the old "tray clean".
    ///
    /// Always spans both modes: the tray has no mode of its own, and its
    /// clean is the one-click "sweep everything safe" gesture.
    private func beginCleanFromRemote() {
        if selection.isEmpty {
            selectAllSafe(allScopes: true)
        }
        requestClean(allScopes: true)
    }

    /// After the scan ends (including cancellation), clear the pending
    /// tray clean request, so that the confirmation panel does not
    /// suddenly pop up after the next scan finishes.
    private func clearPendingClean() {
        pendingCleanAfterScan = false
    }

    // MARK: - Agent Side State Sync (IPC)

    /// Merges the scan / clean state broadcast by the main app.
    ///
    /// Only the scan and clean half is overwritten; stats / topApps /
    /// cpuHistory are polled by the agent itself and must keep updating
    /// even after the main app quits, so they must not be overwritten by
    /// broadcast values. This is also the only source of the scan fields
    /// on the agent side — this process's publish path deliberately does
    /// not touch them (see `publishMenuSnapshot`), otherwise polling would
    /// wipe this half back to 0.
    func applyRemoteScanState(_ state: ScanState) {
        var next = menuSnapshot
        next.phase = ScanPhase(rawValue: state.phase) ?? .idle
        next.cleanPhase = CleanPhase(rawValue: state.cleanPhase) ?? .idle
        next.percent = state.percent
        next.totalSize = state.totalSize
        next.itemCount = state.itemCount
        next.selectedCount = state.selectedCount
        next.selectedSize = state.selectedSize
        if next != menuSnapshot { menuSnapshot = next }
    }

    /// Current scan / clean state, for the main app to broadcast to the
    /// agent.
    func scanStateSnapshot() -> ScanState {
        ScanState(
            phase: phase.rawValue,
            cleanPhase: cleanPhase.rawValue,
            percent: Int((max(0, min(1, progressFraction)) * 100).rounded()),
            totalSize: totalSize,
            itemCount: items.count,
            selectedCount: selection.count,
            selectedSize: selectionStats.globalSize
        )
    }

    /// The state to broadcast before the main app quits: the total
    /// reclaimable size and item count are left as-is, and the selection
    /// is zeroed.
    ///
    /// After close-window-quits, the tray panel header is the only place
    /// the last scan's result is still in front of the user — those are
    /// numbers really scanned out, and if they zeroed along with the
    /// window, the user would have to scan again every time after closing
    /// the window and reopening the tray to see the reclaimable amount.
    /// The selection is the opposite: it belongs to the main window
    /// session, and once the main app is gone there is no meaning in
    /// keeping things checked, so the subtitle should return to
    /// "N items reclaimable" rather than keeping a stale
    /// "N items selected".
    func scanStateForExit() -> ScanState {
        var state = scanStateSnapshot()
        state.selectedCount = 0
        state.selectedSize = 0
        return state
    }

    // MARK: - Hardware Info

    /// Open the hardware page: switch to it and sample a fresh copy.
    ///
    /// Re-sample on every entry: volume free space changes, and the user
    /// may also have changed the display resolution in System Settings.
    /// The whole sample is just a few system calls, so the cost is
    /// negligible.
    func showHardware() {
        showsSettings = false
        showsHardware = true
        showsGeneralCleanup = false
        dismissDiskAnalysis()
        dismissHomebrew()
        dismissAppUninstall()
        dismissLargeFiles()
        hardwareProfile = HardwareSampler.profile()
    }

    /// "Analyze Disk Space" on the hardware page: open the disk analysis
    /// tool — a whole page dedicated to answering "where did the space go",
    /// with a treemap and drill-down navigation. The cleanup scan this used
    /// to trigger answered a different question and left the user on the
    /// item list with no overview.
    func analyzeDiskSpace() {
        showDiskAnalysis()
    }

    /// Opens the settings page from the sidebar, the ⌘, menu item, or the
    /// tray — all three used to set `showsSettings` by hand and each forgot a
    /// different sibling flag.
    func showSettings() {
        showsSettings = true
        showsHardware = false
        showsGeneralCleanup = false
        dismissDiskAnalysis()
        dismissHomebrew()
        dismissAppUninstall()
        dismissLargeFiles()
    }

    /// Opens the disk analysis tool page from the sidebar. Same
    /// embedded-page pattern as the hardware and general cleanup rows: the
    /// detail area swaps entirely, and the main toolbar hides.
    func showDiskAnalysis() {
        guard !showsDiskAnalysis else { return }
        showsDiskAnalysis = true
        selectedCategory = nil
        showsSettings = false
        showsHardware = false
        showsGeneralCleanup = false
        showsHomebrew = false
        showsAppUninstall = false
        showsLargeFiles = false
        if cleanPhase == .done { dismissCleanResult() }
        diskAnalysis.activate()
    }

    /// Leaves the disk analysis page.
    ///
    /// It deliberately does **not** touch the measurement. The scan belongs to
    /// the session, not to the page being visible: cancelling here threw away
    /// minutes of IO whenever the user glanced at another sidebar row, and a
    /// half-measured whole-disk scan left nothing behind at all — `startScan`
    /// drops the tree when it starts, so the tool came back to its start screen
    /// and looked like it had lost its state. The page's own stop button, the
    /// toolbar's rescan/stop and starting a different scan are the only ways to
    /// end it; the sidebar row shows a spinner meanwhile, so a background
    /// measurement is never invisible.
    private func dismissDiskAnalysis() {
        guard showsDiskAnalysis else { return }
        showsDiskAnalysis = false
    }

    /// Opens the Homebrew manager tool page from the sidebar. Same
    /// embedded-page pattern as the other tools: the detail area swaps
    /// entirely and the main toolbar hides. The first entry loads the
    /// snapshot; coming back to a loaded one is instant.
    func showHomebrew() {
        guard !showsHomebrew else { return }
        showsHomebrew = true
        selectedCategory = nil
        showsSettings = false
        showsHardware = false
        showsGeneralCleanup = false
        showsAppUninstall = false
        showsLargeFiles = false
        dismissDiskAnalysis()
        if cleanPhase == .done { dismissCleanResult() }
        homebrew.activate()
    }

    /// Leaves the Homebrew manager page. Deliberately does not touch the
    /// snapshot — same contract as the disk analysis measurement: the load
    /// belongs to the session, not to the page being visible.
    private func dismissHomebrew() {
        guard showsHomebrew else { return }
        showsHomebrew = false
    }

    /// Opens the app uninstall tool page from the sidebar. Same
    /// embedded-page pattern as the other tools: the detail area swaps
    /// entirely and the main toolbar hides. The first entry scans once;
    /// coming back to a scanned list is instant.
    func showAppUninstall() {
        guard !showsAppUninstall else { return }
        showsAppUninstall = true
        selectedCategory = nil
        showsSettings = false
        showsHardware = false
        showsGeneralCleanup = false
        showsHomebrew = false
        showsLargeFiles = false
        dismissDiskAnalysis()
        if cleanPhase == .done { dismissCleanResult() }
        appUninstall.activate()
    }

    /// Leaves the app uninstall page. Deliberately does not touch the scanned
    /// list — same contract as the other tools: the scan belongs to the
    /// session, not to the page being visible, and an in-flight uninstall is
    /// the model's to keep or cancel.
    private func dismissAppUninstall() {
        guard showsAppUninstall else { return }
        showsAppUninstall = false
    }

    /// Opens the large-file analysis tool page from the sidebar. Same
    /// embedded-page pattern as the other tools: the detail area swaps
    /// entirely and the main toolbar hides.
    func showLargeFiles() {
        guard !showsLargeFiles else { return }
        showsLargeFiles = true
        selectedCategory = nil
        showsSettings = false
        showsHardware = false
        showsGeneralCleanup = false
        showsHomebrew = false
        showsAppUninstall = false
        dismissDiskAnalysis()
        if cleanPhase == .done { dismissCleanResult() }
        largeFiles.activate()
    }

    /// Leaves the large-file analysis page. Deliberately does not touch the
    /// walk — same contract as the other tools: the walk belongs to the
    /// session, not to the page being visible, and an in-flight traversal is
    /// the model's to keep or cancel.
    private func dismissLargeFiles() {
        guard showsLargeFiles else { return }
        showsLargeFiles = false
    }

    // MARK: - Memory Release

    /// Panel action: free memory. Requests admin authorization and runs
    /// purge.
    ///
    /// The freed amount is computed by `MemoryReleaser.release` as the
    /// difference in free memory before and after execution: purge hands
    /// file cache back to the free pool, used memory (apps + wired +
    /// compressed) does not change, and only the free amount is its actual
    /// gain.
    ///
    /// Besides the agent's own Toast (visible while the panel is open),
    /// the result is also forwarded to the main app: if the main window is
    /// open, the hint appears in the window the user is looking at.
    func freeMemory() {
        MackitLog.system.info("free memory: requesting authorization")
        Task { [weak self] in
            let outcome = MemoryReleaser.release(
                run: MemoryReleaser.run,
                memoryFree: { SystemStatsSampler.memoryUsage()?.free }
            )

            let style: Banner.Style
            let message: String
            switch outcome {
            case .released(let freed):
                MackitLog.system.info("free memory done: \(freed, privacy: .public) bytes")
                style = .success
                message = L10n.fmt("toast.memoryReleased", Formatters.bytes(freed))
            case .noChange:
                MackitLog.system.info("free memory: no change in free amount")
                style = .info
                message = L10n.tr("toast.memoryReleasedNone")
            case .cancelled:
                MackitLog.system.info("free memory: user cancelled in authorization dialog")
                style = .info
                message = L10n.tr("toast.memoryReleasedCancelled")
            case .failed(let detail):
                MackitLog.system.error("free memory failed: \(detail, privacy: .public)")
                style = .error
                message = L10n.fmt("toast.memoryReleaseFailed", detail)
            }
            self?.showToast(style, message)
            AppBridge.send(.notice, text: message, style: style.wireName)
            self?.refreshStats()
        }
    }

    // MARK: - Derived Data Cache

    /// Filtering, sorting, and stats all depend on items / selection / a
    /// few filter conditions. These are all O(n) computations, and
    /// SwiftUI's body accesses them on every evaluation, becoming a main
    /// thread bottleneck with thousands of items.
    ///
    /// The cache is split into three by "input dimension", each
    /// invalidating independently:
    /// - Visible list: depends on items + category / safe / search / sort
    /// - Category stats: depends only on items
    /// - Selection stats: depends on items + selection
    ///
    /// The key reason for splitting is checking: a single click only
    /// changes selection, and if the three pieces of data shared one
    /// revision number, the whole list would be re-filtered + re-sorted
    /// (O(n log n)), giving a perceptible delay on every click with a few
    /// thousand items. Now checking only recomputes the selection stats.
    private struct VisibleKey: Equatable {
        let items: Int
        let category: JunkCategory?
        let scope: CleanupScope
        let safeOnly: Bool
        let search: String
        let sort: JunkItemComparator
    }

    private struct StatsKey: Equatable {
        let items: Int
        let selection: Int
        let scope: CleanupScope?
    }

    private struct CategoryStats {
        let totals: [JunkCategory: Int64]
        let counts: [JunkCategory: Int]
        let totalSize: Int64
    }

    private struct SelectionStats {
        let size: Int64
        /// Every selected item's size, both modes combined: what the tray
        /// panel reports (its clean sweeps every mode).
        let globalSize: Int64
        let items: [JunkItem]
        let maxRisk: RiskLevel
    }

    /// Change counts for items / selection respectively, used to
    /// invalidate the cache by dimension.
    private var itemsRevision = 0
    private var selectionRevision = 0

    // Cache writes are deliberately excluded from Observation: these are
    // derived data, and the interface invalidates via already-observed
    // keys such as itemsRevision. If cache writes also triggered
    // observation invalidation, every body evaluation (the one driven by
    // NSTableView happens inside an AppKit delegate callback) would cause
    // re-entrant updates — AppKit warns reentrant operation, and
    // "write back → change → re-render → write back" would form a loop
    // maxing out the main thread.
    @ObservationIgnored private var visibleCache: (key: VisibleKey, value: [JunkItem])?
    @ObservationIgnored private var categoryCache: (key: Int, value: CategoryStats)?
    @ObservationIgnored private var selectionCache: (key: StatsKey, value: SelectionStats)?
    @ObservationIgnored private var generalGroupsCache: (key: (Int, Int), value: [GeneralRuleGroupState])?

    /// items changed: both the visible list and category stats are
    /// invalidated.
    private func itemsDidChange() { itemsRevision += 1 }

    /// selection changed: only the selection stats are invalidated; the
    /// visible list stays put.
    private func selectionDidChange() { selectionRevision += 1 }

    /// The currently visible items (after filtering + sorting).
    var visibleItems: [JunkItem] {
        let key = VisibleKey(
            items: itemsRevision,
            category: selectedCategory,
            scope: cleanupScope,
            safeOnly: safeOnly,
            search: searchText,
            sort: sortComparator
        )
        if let cached = visibleCache, cached.key == key { return cached.value }
        let value = filterAndSort()
        visibleCache = (key, value)
        return value
    }

    /// The total size of each category in the sidebar, used to display
    /// sizes.
    var categoryTotals: [JunkCategory: Int64] { categoryStats.totals }

    var categoryCounts: [JunkCategory: Int] { categoryStats.counts }

    /// Grand total across both modes: what the tray panel reports.
    var totalSize: Int64 { categoryStats.totalSize }

    /// Total size of the developer feature's items: what the sidebar's "all
    /// items" row reports.
    var developerTotalSize: Int64 {
        categoryStats.totals.reduce(0) { $0 + ($1.key.scope == .developer ? $1.value : 0) }
    }

    /// Item count of the developer feature.
    var developerItemCount: Int {
        categoryStats.counts.reduce(0) { $0 + ($1.key.scope == .developer ? $1.value : 0) }
    }

    /// The categories the main window's list offers, in sidebar order,
    /// including empty ones only while selected (so the filter row does not
    /// vanish from under the cursor). Always the developer feature's: the
    /// general module lives on its own page.
    var developerCategories: [JunkCategory] {
        JunkCategory.ordered.filter { category in
            category.scope == .developer
                && (categoryCounts[category, default: 0] > 0 || category == selectedCategory)
        }
    }

    private var categoryStats: CategoryStats {
        if let cached = categoryCache, cached.key == itemsRevision { return cached.value }
        var totals: [JunkCategory: Int64] = [:]
        var counts: [JunkCategory: Int] = [:]
        var total: Int64 = 0
        for item in items {
            totals[item.category, default: 0] += item.size
            counts[item.category, default: 0] += 1
            total += item.size
        }
        let value = CategoryStats(totals: totals, counts: counts, totalSize: total)
        categoryCache = (itemsRevision, value)
        return value
    }

    /// The size of the currently selected items.
    var selectedSize: Int64 { selectionStats.size }

    /// The items a pending confirmation will clean: the selection filtered
    /// by the mode the clean was requested for (nil = every mode, the tray
    /// one-click path). This is what the confirmation dialog lists and what
    /// the clean engine receives.
    var selectedItems: [JunkItem] { selectionStats.items }

    /// The highest risk level among the selected items, used for the
    /// warning style of the confirmation dialog.
    var selectedMaxRisk: RiskLevel { selectionStats.maxRisk }

    /// Selected items and size within the mode the window is currently
    /// showing: what the toolbar's clean button reports.
    var scopeSelectedItems: [JunkItem] {
        selectionStats.items.filter { $0.category.scope == cleanupScope }
    }

    var scopeSelectedSize: Int64 {
        scopeSelectedItems.reduce(0) { $0 + $1.size }
    }

    private var selectionStats: SelectionStats {
        let key = StatsKey(items: itemsRevision, selection: selectionRevision, scope: pendingCleanScope)
        if let cached = selectionCache, cached.key == key { return cached.value }
        var size: Int64 = 0
        var globalSize: Int64 = 0
        var maxRisk: RiskLevel?
        var selected: [JunkItem] = []
        selected.reserveCapacity(selection.count)
        for item in items where selection.contains(item.id) {
            globalSize += item.size
            if let scope = pendingCleanScope, item.category.scope != scope { continue }
            size += item.size
            if let current = maxRisk, item.risk > current { maxRisk = item.risk }
            else if maxRisk == nil { maxRisk = item.risk }
            selected.append(item)
        }
        let value = SelectionStats(size: size, globalSize: globalSize, items: selected, maxRisk: maxRisk ?? .safe)
        selectionCache = (key, value)
        return value
    }

    // MARK: - General Cleanup Page

    /// General-page rows checked outside the item selection. Two kinds of
    /// rows need it: rows the scan found nothing for — their checkbox cannot
    /// be derived from items that do not exist, and without a record of the
    /// check the row is inert (clicking it changes nothing and the row reads
    /// as broken) — and rows arriving with the remembered selection, which
    /// must show checked even when the new scan finds nothing for them.
    /// Restarted from the saved selection on every scan start
    /// (see `resetGeneralRowChecks`).
    var handCheckedGeneralRows: Set<String> { selectionState.handCheckedRows }

    /// One row of the general cleanup page with its found items rolled up.
    struct GeneralRuleRowState {
        let row: GeneralRuleRow
        let items: [JunkItem]
        let size: Int64
        let selectedCount: Int
        let selectedSize: Int64
        /// The row is checked, but not through its items: the scan found
        /// nothing for it, or it came in with the remembered selection.
        let isCheckedByHand: Bool
        /// The row's entries grouped below the header; empty for a flat row.
        /// Sorted by size, largest first, same as the main list.
        let subRows: [GeneralSubRowState]

        /// All of the row's items are checked. A row with no items has no
        /// items to derive from, so it is checked exactly when it was
        /// checked by hand.
        var isFullySelected: Bool {
            items.isEmpty ? isCheckedByHand : selectedCount == items.count
        }

        var isPartiallySelected: Bool { !isFullySelected && selectedCount > 0 }
    }

    /// One sub-row of a grouped general-page row: a single language, or one
    /// app's junk. Clicking it moves exactly that group's items, so the user
    /// can keep one language — or one app's caches — while sweeping the rest.
    struct GeneralSubRowState: Identifiable {
        /// The group key: the language code, or the owning app's display name.
        let id: String
        let title: String
        /// Secondary line under the title: the apps a language pack came
        /// from. nil when the title already names the owner (per-app rows).
        let detail: String?
        let itemIDs: [String]
        let size: Int64
        let selectedCount: Int

        var isFullySelected: Bool { selectedCount == itemIDs.count }
        var isPartiallySelected: Bool { !isFullySelected && selectedCount > 0 }
    }

    /// One group of the general cleanup page.
    struct GeneralRuleGroupState: Identifiable {
        let group: GeneralCleanGroup
        let rows: [GeneralRuleRowState]
        let totalSize: Int64
        let selectedSize: Int64

        var id: String { group.rawValue }

        /// Group-level selection state for the header's tri-state checkbox.
        /// Rows with nothing found don't count as selected, so a group whose
        /// rows are all empty reads as unselected rather than "all checked".
        var isFullySelected: Bool {
            rows.contains { !$0.items.isEmpty } && rows.allSatisfy { $0.items.isEmpty || $0.isFullySelected }
        }

        var isPartiallySelected: Bool {
            !isFullySelected && rows.contains { $0.isFullySelected || $0.isPartiallySelected }
        }
    }

    /// The general cleanup page's content: every layout row, with the items
    /// found for it rolled up (possibly none — the row still shows, with its
    /// safety badge, so the page reads as the full checklist of what Mackit
    /// checks).
    var generalCleanGroups: [GeneralRuleGroupState] {
        let key = (itemsRevision, selectionRevision)
        if let cached = generalGroupsCache, cached.key == key { return cached.value }
        let value = buildGeneralGroups()
        generalGroupsCache = (key, value)
        return value
    }

    /// Everything the general module found, selected or not: the big number
    /// in the page header.
    var generalTotalSize: Int64 {
        generalCleanGroups.reduce(0) { $0 + $1.totalSize }
    }

    private func buildGeneralGroups() -> [GeneralRuleGroupState] {
        var byRule: [String: [JunkItem]] = [:]
        for item in items where item.category.scope == .general {
            byRule[item.ruleID, default: []].append(item)
        }
        return GeneralCleanGroup.allCases.map { group in
            let rows = GeneralCleanLayout.rows(of: group).map { row -> GeneralRuleRowState in
                let rowItems = row.ruleIDs.flatMap { byRule[$0] ?? [] }
                let selected = rowItems.filter { selection.contains($0.id) }
                return GeneralRuleRowState(
                    row: row,
                    items: rowItems,
                    size: rowItems.reduce(0) { $0 + $1.size },
                    selectedCount: selected.count,
                    selectedSize: selected.reduce(0) { $0 + $1.size },
                    isCheckedByHand: handCheckedGeneralRows.contains(row.id),
                    subRows: buildSubRows(for: row, items: rowItems)
                )
            }
            return GeneralRuleGroupState(
                group: group,
                rows: rows,
                totalSize: rows.reduce(0) { $0 + $1.size },
                selectedSize: rows.reduce(0) { $0 + $1.selectedSize }
            )
        }
    }

    /// Groups a row's items into sub-rows by the row's mode: one per language
    /// for the language-files row, one per app for the app-junk row. The
    /// grouping itself belongs to the selection model; this only adds the
    /// display title and the selected count the page shows.
    private func buildSubRows(for row: GeneralRuleRow, items: [JunkItem]) -> [GeneralSubRowState] {
        // One pass for the apps behind each language: the page rebuilds these
        // on every check, and a pass per sub-row would multiply that by the
        // number of languages.
        let languageApps = row.subRowMode == .byLanguage ? appsByLanguage(in: items) : [:]
        return selectionState.subRowGroups(of: row, items: items).map { group in
            GeneralSubRowState(
                id: group.key,
                title: subRowTitle(key: group.key, mode: row.subRowMode),
                detail: languageApps[group.key].map { ListFormatter.localizedString(byJoining: $0) },
                itemIDs: Array(group.itemIDs),
                size: group.size,
                selectedCount: group.itemIDs.count { selectionState.ids.contains($0) }
            )
        }
    }

    /// The apps behind each language: language code → app names in scan order,
    /// deduplicated.
    ///
    /// A language sub-row is one language across every app that ships it
    /// ("Japanese · 3 apps"), so the language name alone does not say which
    /// apps change when it is checked — and the page has nowhere else to say
    /// it. The code comes from the same `subRowKey` the grouping uses, so the
    /// two cannot drift.
    private func appsByLanguage(in items: [JunkItem]) -> [String: [String]] {
        var names: [String: [String]] = [:]
        var seen: [String: Set<String>] = [:]
        for item in items {
            guard let name = item.appName, !name.isEmpty,
                  let code = selectionState.subRowKey(for: item, mode: .byLanguage) else { continue }
            if seen[code, default: []].insert(name).inserted {
                names[code, default: []].append(name)
            }
        }
        return names
    }

    /// The sub-row's display title. Language sub-rows show the language's own
    /// name ("Japanese", "Tamil"), in the language Mackit's own UI is currently
    /// rendered in — the same convention as System Settings' language list.
    private func subRowTitle(key: String, mode: GeneralSubRowMode) -> String {
        switch mode {
        case .flat:
            return key
        case .byLanguage:
            let locale = Locale(identifier: AppLanguage.running.effective.rawValue)
            // Returns nil for a code Foundation has no name for; the code
            // itself is a better sub-row title than a blank one.
            return locale.localizedString(forLanguageCode: key) ?? key
        case .byApp:
            return key
        }
    }

    /// Checks or unchecks every item of a general-page row at once. A row the
    /// scan found nothing for has no items to move, so its check is recorded
    /// by hand instead — without that record the row would be inert and
    /// ignore every click.
    func setRowSelected(_ row: GeneralRuleRow, selected: Bool) {
        if selectionState.setRow(row, selected: selected, items: items) {
            selectionDidChange()
            publishMenuSnapshot(force: true)
        }
    }

    /// Checks or unchecks one sub-row of a grouped row — a single language,
    /// or a single app's junk — leaving the rest of the row as it was.
    func setSubRowSelected(_ row: GeneralRuleRow, key: String, selected: Bool) {
        if selectionState.setSubRow(of: row, key: key, selected: selected, items: items) {
            selectionDidChange()
            publishMenuSnapshot(force: true)
        }
    }

    /// Checks or unchecks a whole general-page group at once — the group
    /// header is the toggle, for when the user wants all of "System Junk"
    /// without clicking each row. Rows that found nothing have no items to
    /// move, so the group's hand-checked rows move with the toggle.
    func setGroupSelected(_ group: GeneralCleanGroup, selected: Bool) {
        if selectionState.setGroup(group, selected: selected, items: items) {
            selectionDidChange()
            publishMenuSnapshot(force: true)
        }
    }

    /// Restarts the general page's hand-checked rows for a new scan: the
    /// remembered selection when the user saved one (so a remembered row
    /// shows checked even if the new scan finds nothing for it), otherwise
    /// nothing — the built-in default pre-check covers the rest.
    func resetGeneralRowChecks() {
        if selectionState.restartHandCheckedRows() {
            selectionDidChange()
        }
    }

    /// Filters in a single pass, then sorts by the current sort mode.
    /// Search matching uses item.searchBlob (the whole text lowercased at
    /// the creation time), avoiding three lowercased() calls per item on every
    /// keystroke.
    ///
    /// Sorting itself is driven by SwiftUI's `Table(sortOrder:)`: header
    /// clicks rewrite `sortComparator` (including ascending/descending),
    /// and this only sorts according to its semantics.
    private func filterAndSort() -> [JunkItem] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result: [JunkItem] = []
        result.reserveCapacity(items.count)

        for item in items {
            if let selectedCategory, item.category != selectedCategory { continue }
            if item.category.scope != cleanupScope { continue }
            if safeOnly, item.risk != .safe { continue }
            if !needle.isEmpty, !item.searchBlob.contains(needle) { continue }
            result.append(item)
        }

        let comparator = sortComparator
        result.sort { comparator.sorts($0, before: $1) }
        return result
    }

    var isBusy: Bool { phase == .scanning || cleanPhase == .cleaning }

    // MARK: - Scan

    func startScan() {
        guard phase != .scanning else { return }
        scanTask?.cancel()
        cleanTask?.cancel()

        items = []
        selectionState.reset()
        resetGeneralRowChecks()
        cleanOutcomes = []
        cleanPhase = .idle
        phase = .scanning
        progressFraction = 0
        progressLabel = L10n.tr("scan.enumerating")
        // Clear the previous cleanup summary too: if kept, the sidebar and
        // panel would already be reporting how much space was freed last
        // time before the new scan has even finished.
        lastReclaimed = 0
        lastFailures = 0
        cleanProgress = 0
        cleanCurrentTitle = ""
        pendingRemoval = []
        dismissToast()
        itemsDidChange()
        selectionDidChange()
        publishMenuSnapshot(force: true)
        scanStartedAt = .now
        MackitLog.scan.info("scan started: \(self.projectRoots.count, privacy: .public) project roots, CLI \(self.includeCLI, privacy: .public), app junk \(self.includeApps, privacy: .public)")

        let options = ScanOptions(
            autoSelectRisk: autoSelectRisk,
            projectRoots: projectRoots,
            includeCLI: includeCLI
        )

        let task = Task { [weak self] in
            guard let self else { return }
            let stream = ScanEngine.scan(
                rules: RulesCatalog.scanRules,
                cliRules: RulesCatalog.cliRules,
                options: options
            )
            for await event in stream {
                if Task.isCancelled { return }
                self.apply(event)
            }
            guard !Task.isCancelled else { return }
            if let startedAt = self.scanStartedAt {
                MackitLog.scan.info("rule scan phase finished: \(self.items.count, privacy: .public) items, took \(MackitLog.duration(.now - startedAt), privacy: .public)")
            }

            // App junk comes before project directories: it always
            // enumerates two directories, is quick and predictable, letting
            // the general module's app-junk row appear as early as possible;
            // project roots can be very large, so they go last.
            if self.includeApps {
                await self.scanAppJunk()
            }
            guard !Task.isCancelled else { return }

            // Language files and Downloads come after apps but before project
            // directories: both enumerate only a couple of fixed directories
            // and finish in about a second, while project roots can be huge
            // and stay last.
            await self.scanLanguageFiles()
            guard !Task.isCancelled else { return }
            await self.scanDownloads()
            guard !Task.isCancelled else { return }

            // Scan custom project directories after the static rules, so
            // cache items show up as early as possible
            if !self.projectRoots.isEmpty {
                self.progressLabel = L10n.tr("scan.projectRoots")
                await self.scanProjectRoots()
            }
            guard !Task.isCancelled else { return }

            self.phase = .done
            self.progressFraction = 1
            self.progressLabel = L10n.tr("scan.finished")
            self.volumeUsage = .home()
            self.publishMenuSnapshot(force: true)
            // Tray "Clean" arrived during or before the scan: add the
            // confirmation panel as soon as the scan finishes, so the user
            // does not have to go back to the panel and click a second
            // time.
            if self.pendingCleanAfterScan {
                self.pendingCleanAfterScan = false
                self.selectAllSafe(allScopes: true)
                self.requestClean(allScopes: true)
            }
            if let startedAt = self.scanStartedAt {
                let elapsed = MackitLog.duration(.now - startedAt)
                MackitLog.scan.info("scan finished: \(self.items.count, privacy: .public) items, \(self.totalSize, privacy: .public) bytes total, took \(elapsed, privacy: .public)")
                self.scanStartedAt = nil
            }
        }
        scanTask = task
    }

    /// Consumes one scan event. Visible within the module so tests can
    /// drive it directly; not exposed externally.
    func apply(_ event: ScanEvent) {
        switch event {
        case .progress(let completed, let total, let label):
            progressLabel = label
            progressFraction = total > 0 ? Double(completed) / Double(total) : 0

        case .discovered(let batch):
            items.append(contentsOf: batch)
            applyDefaultSelection(batch)
            itemsDidChange()

        case .finished(let count):
            // Wrapping up is uniformly handled by the end of startScan's
            // task; here we only record the count
            progressLabel = L10n.fmt(count == 1 ? "scan.foundFinishing.one" : "scan.foundFinishing.other", count)
            progressFraction = 1
        }
        // Scan events pour in at a per-work-unit cadence; here they are
        // only fed to the menu bar at downsampled intervals
        publishMenuSnapshot()
    }

    /// Applies the pre-check policy to a batch of newly discovered items.
    /// The rules live in `CleanupSelection`; this only invalidates the caches
    /// and republishes.
    private func applyDefaultSelection(_ batch: [JunkItem]) {
        if selectionState.applyDefaultPolicy(to: batch, autoSelect: autoSelectRisk) {
            selectionDidChange()
        }
    }

    /// The general-page row an item belongs to (for the saved-selection
    /// setting). Items from an unknown rule id roll into no row and are
    /// never remembered — the layout test keeps that from happening.
    static func generalRowID(for item: JunkItem) -> String {
        GeneralCleanLayout.rowID(forRuleID: item.ruleID) ?? ""
    }

    /// Whether the general page's current selection differs from what the
    /// next scan would pre-check — i.e. whether there is a new setting
    /// worth remembering. The confirmation sheet uses this to decide
    /// whether to show the "remember this selection" toggle.
    func generalSelectionDiffersFromSaved() -> Bool {
        selectionState.selectionDiffersFromDefault(items: items)
    }

    /// Whether the confirmation sheet should offer to remember the general
    /// page's row selection. Only for cleans launched from the general
    /// module: the developer cleanup and the tray's one-click sweep have no
    /// per-row selection of their own to remember.
    var showsRememberGeneralPrompt: Bool {
        pendingCleanScope == .general && generalSelectionDiffersFromSaved()
    }

    /// Remembers the general page's current row selection, so every later
    /// scan pre-checks exactly these rows.
    func rememberGeneralSelection() {
        selectionState.rememberCurrentRows(items: items)
        showToast(.success, L10n.tr("toast.generalSelectionRemembered"))
    }

    /// Whether a row selection is remembered. While one is, the general page's
    /// header offers "restore defaults" instead of "remember this selection" —
    /// otherwise a remembered selection would be a one-way door with no way
    /// back to the built-in default.
    var hasRememberedGeneralSelection: Bool {
        selectionState.hasRememberedSelection
    }

    /// Drops the remembered selection and re-applies the built-in default
    /// (the rows the layout pre-checks) to the items the current scan already
    /// found, so the shortcut works without forcing a rescan.
    func restoreDefaultGeneralSelection() {
        if selectionState.restoreDefaultSelection(items: items) {
            selectionDidChange()
            publishMenuSnapshot(force: true)
            showToast(.info, L10n.tr("toast.generalDefaultsRestored"))
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        phase = .done
        progressLabel = L10n.tr("scan.cancelled")
        clearPendingClean()
        lastReclaimed = 0
        lastFailures = 0
        cleanProgress = 0
        cleanCurrentTitle = ""
        pendingRemoval = []
        if let startedAt = scanStartedAt {
            MackitLog.scan.info("scan cancelled by user: \(self.items.count, privacy: .public) items found, took \(MackitLog.duration(.now - startedAt), privacy: .public)")
            scanStartedAt = nil
        }
        publishMenuSnapshot(force: true)
    }

    // MARK: - Selection

    func toggle(_ item: JunkItem) {
        if selectionState.setItem(item.id, selected: !isSelected(item)) {
            selectionDidChange()
            publishMenuSnapshot(force: true)
        }
    }

    func selectAllVisible() {
        if selectionState.setItems(Set(visibleItems.map(\.id)), selected: true) {
            selectionDidChange()
            publishMenuSnapshot(force: true)
        }
    }

    func deselectAllVisible() {
        if selectionState.setItems(Set(visibleItems.map(\.id)), selected: false) {
            selectionDidChange()
            publishMenuSnapshot(force: true)
        }
    }

    /// Checks every safe item. Defaults to the mode the window is currently
    /// showing; the tray one-click clean passes `allScopes: true` so a
    /// regular user's browser caches get swept even though the window last
    /// sat in developer mode.
    func selectAllSafe(allScopes: Bool = false) {
        if selectionState.selectAllSafe(items, scopes: allScopes ? nil : [cleanupScope]) {
            selectionDidChange()
            publishMenuSnapshot(force: true)
        }
    }

    /// Switching category in the sidebar: collapse the cleanup result page
    /// in passing.
    ///
    /// While the result page occupies the detail area, clicking a category
    /// row that only changes selectedCategory makes the interface look
    /// completely unresponsive — the user thinks they misclicked, when in
    /// fact the filter has already changed. Here cleanPhase is also pulled
    /// back to idle, so the detail area follows the selection.
    func selectCategory(_ category: JunkCategory?) {
        selectedCategory = category
        showsSettings = false
        showsHardware = false
        showsGeneralCleanup = false
        dismissDiskAnalysis()
        dismissHomebrew()
        dismissAppUninstall()
        dismissLargeFiles()
        if cleanPhase == .done { dismissCleanResult() }
    }

    /// Opens the general cleanup page from the sidebar.
    func showGeneralCleanup() {
        guard !showsGeneralCleanup else { return }
        showsGeneralCleanup = true
        selectedCategory = nil
        showsSettings = false
        showsHardware = false
        dismissDiskAnalysis()
        dismissHomebrew()
        dismissAppUninstall()
        dismissLargeFiles()
        if cleanPhase == .done { dismissCleanResult() }
    }

    func isSelected(_ item: JunkItem) -> Bool { selection.contains(item.id) }

    // MARK: - Cleanup

    /// Enters confirmation for the current mode's selection. The tray
    /// one-click path passes `allScopes: true` to confirm across both
    /// modes instead.
    func requestClean(allScopes: Bool = false) {
        guard !selection.isEmpty else { return }
        // Cleaning must go through list confirmation first. There is
        // deliberately no "skip confirmation" toggle here: the cost of
        // mistakenly deleting caches/archives far outweighs clicking the
        // button one more time.
        pendingCleanScope = allScopes ? nil : cleanupScope
        cleanPhase = .confirming
        publishMenuSnapshot(force: true)
    }

    /// Cancel confirmation, returning to idle.
    func cancelConfirmation() {
        cleanPhase = .idle
        // The clean intent only lives while a confirmation is pending; a
        // stale one would keep filtering the selection stats after the user
        // navigated on to the other feature's page.
        pendingCleanScope = nil
        publishMenuSnapshot(force: true)
    }

    func beginClean() {
        guard !selection.isEmpty else { return }
        cleanTask?.cancel()
        cleanPhase = .cleaning
        cleanProgress = 0
        cleanOutcomes = []
        cleanCurrentTitle = ""
        publishMenuSnapshot(force: true)
        cleanStartedAt = .now
        MackitLog.clean.info("clean started: \(self.selectedItems.count, privacy: .public) items, \(self.selectedSize, privacy: .public) bytes total, move to Trash \(self.moveToTrash, privacy: .public)")

        let targets = selectedItems
        let useTrash = moveToTrash

        let task = Task { [weak self] in
            guard let self else { return }
            let stream = CleanEngine.clean(items: targets, moveToTrash: useTrash)
            for await event in stream {
                if Task.isCancelled { return }
                self.applyClean(event)
            }
        }
        cleanTask = task
    }

    /// Item ids pending removal. One is recorded for each successful
    /// clean, and all are removed from items in one batch at the end.
    ///
    /// Each individual removeAll is O(n), so cleaning k items costs
    /// O(n×k) in total, becoming a main thread bottleneck when cleaning
    /// over a thousand items out of thousands.
    private var pendingRemoval: Set<String> = []

    private func applyClean(_ event: CleanEvent) {
        switch event {
        case .started(let total):
            cleanCurrentTitle = L10n.tr("clean.preparing")
            cleanProgress = total > 0 ? 0 : 1
            pendingRemoval = []

        case .progress(let completed, let total, let current):
            cleanProgress = total > 0 ? Double(completed) / Double(total) : 0
            cleanCurrentTitle = current

        case .outcome(let outcome):
            cleanOutcomes.append(outcome)
            if outcome.succeeded {
                pendingRemoval.insert(outcome.itemID)
            }

        case .finished(let reclaimed, let failures):
            lastReclaimed = reclaimed
            lastFailures = failures
            cleanProgress = 1
            cleanPhase = .done
            volumeUsage = .home()
            if let startedAt = cleanStartedAt {
                MackitLog.clean.info("clean finished: freed \(reclaimed, privacy: .public) bytes, \(failures, privacy: .public) failures, took \(MackitLog.duration(.now - startedAt), privacy: .public)")
                cleanStartedAt = nil
            }
            for outcome in cleanOutcomes where !outcome.succeeded {
                MackitLog.clean.error("clean failed \"\(outcome.title, privacy: .public)\": \(outcome.message, privacy: .public)")
            }

            // Cleanup results are reported via Toast; the failure count
            // must appear in the hint, so the user does not only see
            // "success" and miss the failures.
            //
            // A clean that recycled anything has not freed the bytes yet —
            // they come back when the Trash is emptied — so the hint says
            // "moved" there, the same rule the result summary follows.
            let moved = lastCleanMovedToTrash
            if failures == 0 {
                showToast(.success, L10n.fmt(
                    moved ? "toast.moved" : "toast.reclaimed",
                    Formatters.bytes(reclaimed)
                ))
            } else {
                showToast(.error, L10n.fmt(
                    moved
                        ? (failures == 1 ? "toast.movedWithFailures.one" : "toast.movedWithFailures.other")
                        : (failures == 1 ? "toast.reclaimedWithFailures.one" : "toast.reclaimedWithFailures.other"),
                    Formatters.bytes(reclaimed), failures
                ))
            }

            // Remove in one batch, triggering only one cache invalidation
            removeCleanedItems(pendingRemoval)
            pendingRemoval = []
            pendingCleanScope = nil
            publishMenuSnapshot(force: true)
        }
    }

    /// Drops the cleaned items from the list in one batch.
    ///
    /// The selection deliberately survives: a clean acts on the user's
    /// selection, it does not reset it. What the user checked stays checked —
    /// items whose clean failed stay checked so they can be retried, and rows
    /// whose items were all cleaned keep their check as a hand-checked row, so
    /// the page still shows the curation instead of reading as "nothing
    /// selected". Only a new scan restarts the selection.
    ///
    /// The selection must be updated *before* the items leave the list: which
    /// rows lost their items is computed from the full list.
    ///
    /// Visible within the module so tests can drive it directly.
    func removeCleanedItems(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        selectionState.applyCleanResult(ids, items: items)
        items.removeAll { ids.contains($0.id) }
        itemsDidChange()
        selectionDidChange()
    }

    private func removeItem(id: String) {
        selectionState.discard([id])
        items.removeAll { $0.id == id }
        itemsDidChange()
        selectionDidChange()
        publishMenuSnapshot(force: true)
    }

    func dismissCleanResult() {
        cleanPhase = .idle
        cleanOutcomes = []
        publishMenuSnapshot(force: true)
    }

    func cancelClean() {
        cleanTask?.cancel()
        cleanTask = nil
        // Already-deleted items must disappear from the list at once: the
        // clean engine reports completed results via .finished even after
        // cancellation, but the consume loop returns directly on cancel
        // and never gets there. Without cutting here, deleted rows would
        // stay in the list padding the count, and clicking clean again
        // would try to delete already-nonexistent paths a second time.
        if !pendingRemoval.isEmpty {
            let alreadyRemoved = pendingRemoval.count
            removeCleanedItems(pendingRemoval)
            pendingRemoval = []
            MackitLog.clean.info("clean cancelled by user: \(alreadyRemoved, privacy: .public) completed items removed from the list")
        } else {
            MackitLog.clean.info("clean cancelled by user: no completed items")
        }
        cleanOutcomes = []
        cleanProgress = 0
        cleanCurrentTitle = ""
        cleanStartedAt = nil
        pendingCleanScope = nil
        cleanPhase = .idle
        publishMenuSnapshot(force: true)
    }

    // MARK: - Operation Hints (Toast)

    /// Pops an operation hint, auto-dismissed after `Banner.autoDismissSeconds`.
    /// A new hint cancels the previous one's timer task, so hints are not
    /// cleared prematurely during rapid successive operations.
    func showToast(_ style: Banner.Style, _ message: String) {
        bannerDismissTask?.cancel()
        banner = Banner(style: style, message: message)

        bannerDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Banner.autoDismissSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    /// Immediately dismiss the current hint.
    func dismissToast() {
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        banner = nil
    }

    // MARK: - Item Actions

    /// Shows the item in Finder.
    ///
    /// A folder is opened itself, a file its enclosing folder — and a folder
    /// that LaunchServices would hand to another application (an application
    /// bundle, a preference pane) is revealed through its enclosing folder
    /// instead, so the click never starts something. See `RevealInFinder`.
    func revealInFinder(_ item: JunkItem) {
        guard !item.path.isEmpty else { return }
        let url = URL(fileURLWithPath: item.path)
        if item.isDirectory {
            RevealInFinder.show(folder: url)
        } else {
            RevealInFinder.show(file: url)
        }
    }

    func openInTerminal(_ item: JunkItem) {
        guard !item.path.isEmpty else { return }
        let directory = item.isDirectory
            ? URL(fileURLWithPath: item.path)
            : URL(fileURLWithPath: item.path).deletingLastPathComponent()
        // The path is embedded into an AppleScript string literal: quotes
        // and backslashes must be escaped first, or the assembled script
        // will be syntactically wrong and the user only sees
        // "Failed to open Terminal", with no clue that special characters
        // in the path caused it. Backslashes must come before quotes.
        let escaped = Self.appleScriptEscaped(directory.path)
        let source = "tell application \"Terminal\"\n" +
            "activate\n" +
            "do script \"cd \" & quoted form of \"\(escaped)\"\n" +
            "end tell"
        guard let appleScript = NSAppleScript(source: source) else {
            showToast(.error, L10n.tr("toast.scriptFailed"))
            return
        }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        if error != nil {
            showToast(.error, L10n.tr("toast.terminalFailed"))
        }
    }

    /// AppleScript string literal escaping.
    static func appleScriptEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Puts text on the general pasteboard. A seam so a unit test's copy does
    /// not clobber the developer's clipboard; never reassigned in production,
    /// where it writes the real pasteboard.
    var pasteboardSink: @MainActor (String) -> Void = { Clipboard.copy($0) }

    /// Copies text and confirms it with a toast.
    ///
    /// A copy that succeeds silently reads as a dead button — the user cannot
    /// tell "it worked" from "nothing happened" without pasting somewhere
    /// first. The action log's copy already confirmed itself; this is that
    /// confirmation for every other copy affordance: the Homebrew command
    /// rows, the diagnostics and config copies, and the item list's Copy Path.
    func copyToClipboard(_ text: String) {
        pasteboardSink(text)
        showToast(.success, L10n.tr("toast.copied"))
    }

    func copyPath(_ item: JunkItem) {
        let text = item.path.isEmpty ? item.command.joined(separator: " ") : item.path
        copyToClipboard(text)
    }

    func trashSingle(_ item: JunkItem) {
        guard !item.path.isEmpty else { return }
        let url = URL(fileURLWithPath: item.path)
        guard !FileSystem.isProtected(url.path) else {
            showToast(.error, L10n.tr("toast.protectedPath"))
            return
        }
        // An entry already in the Trash cannot be "moved to the Trash": the
        // only thing left to do with it is delete it permanently, and this
        // action carries no confirmation. Finder asks before doing that
        // ("This item is already in the Trash…"); so this refuses and points
        // at the clean flow, whose sheet is where permanent deletion is agreed
        // to. Silently deleting here would be the worst of both.
        guard !FileSystem.isInTrash(url) else {
            showToast(.info, L10n.tr("toast.alreadyInTrash"))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            // A move that left the entry in place did not happen: the API
            // reports success for a recycle it did not perform.
            guard await CleanEngine.moveToTrashVerified(url) else {
                MackitLog.clean.error("single item could not be moved to the Trash: \(item.title, privacy: .public)")
                self.showToast(.error, L10n.tr("toast.trashFailed"))
                return
            }
            self.removeItem(id: item.id)
            self.volumeUsage = .home()
            self.showToast(.success, L10n.fmt("toast.trashed", item.title))
        }
    }

    // MARK: - Settings Persistence

    /// The write side of settings persistence.
    ///
    /// A seam for tests: the VM's init reads the real shared settings file,
    /// so a test that exercises a save — the remembered row selection, say —
    /// needs somewhere to put it other than the developer's own settings.
    /// Never reassigned in production, where it writes the shared file.
    var settingsSink: @MainActor ([String: Any]) -> Void = { SharedStore.saveSettings($0) }

    /// Applies the crash-collection preference to this process — arming or
    /// disarming the handlers.
    ///
    /// A seam for the same reason as `settingsSink`: the VM is constructed by
    /// tests as freely as by the app, and a test that flips the setting must
    /// not install signal handlers in the test runner itself.
    var crashCollectionApply: @MainActor (Bool) -> Void = { CrashCollector.setEnabled($0) }

    private func loadSettings() {
        // The two processes (main app and tray agent) each hold a VM, and
        // settings live in a shared file, so a change on one side becomes
        // visible to the other.
        loadSettings(from: SharedStore.loadSettings())
    }

    /// Applies one settings dictionary.
    ///
    /// Split out from `loadSettings` so a test can feed a dictionary directly
    /// instead of reading the developer's own shared file — the read-side
    /// counterpart of the `settingsSink` seam on the write side.
    func loadSettings(from values: [String: Any]) {
        // autoSelectRisk is stored as an Int (AutoSelectLevel.rawValue).
        // It was once stored as a string historically; both paths are
        // accepted, and when it cannot be read, keep the initial .none.
        if let raw = values["autoSelectRisk"] as? Int {
            autoSelectRisk = AutoSelectLevel(rawValue: raw) ?? .none
        } else if let legacy = values["autoSelectRisk"] as? String, let raw = Int(legacy) {
            autoSelectRisk = AutoSelectLevel(rawValue: raw) ?? .none
        }
        if let value = values["moveToTrash"] as? Bool {
            moveToTrash = value
        }
        if let value = values["includeCLI"] as? Bool {
            includeCLI = value
        }
        if let value = values["includeApps"] as? Bool {
            includeApps = value
        }
        if let value = values["collectCrashLogs"] as? Bool {
            collectCrashLogs = value
        }
        // The remembered general-cleanup row selection. Absent (or empty)
        // means "never saved" and falls back to the built-in default.
        if let rows = values["generalSelectedRows"] as? [String], !rows.isEmpty {
            generalSelectedRows = Set(rows)
        } else {
            generalSelectedRows = nil
        }
        // Deduplicated and emptied of blank entries on load: the array is
        // persisted as-is, and a settings file that repeats a path (a hand
        // edit, or an older writer) would put duplicate ids into the settings
        // list's ForEach — undefined territory for row identity.
        var roots = Set<String>()
        projectRoots = (values["projectRoots"] as? [String] ?? [])
            .filter { !$0.isEmpty && roots.insert($0).inserted }
        // The three monitoring toggles default to all on: the monitoring
        // section is a feature the user actively asks for, and defaulting
        // to collapsed would turn "added a display" into "added nothing".
        if let value = values["showMenuBarCPU"] as? Bool {
            showMenuBarCPU = value
        }
        if let value = values["showMenuBarMemory"] as? Bool {
            showMenuBarMemory = value
        }
        if let value = values["showMenuBarTemperature"] as? Bool {
            showMenuBarTemperature = value
        }
        // Defaults to on: absent means the user never touched the switch, and
        // dropping the icon on an upgrade would be a silent visual change.
        if let value = values["showMenuBarLogo"] as? Bool {
            showMenuBarLogo = value
        }
        if let value = values["showDesktopStats"] as? Bool {
            showDesktopStats = value
        }
        // The persisted launch-at-login choice, with the system registration as
        // the fallback for settings files written before the key existed (an
        // upgrade). The rule lives in LaunchAtLogin because the launch-time
        // repair reads the same choice through it.
        launchAtLogin = LaunchAtLogin.preferredIntent(from: values)
    }

    func saveSettings() {
        // Only write the keys this VM is responsible for; SharedStore
        // merges with the other keys in the file and replaces wholesale.
        settingsSink([
            "autoSelectRisk": autoSelectRisk.rawValue,
            "moveToTrash": moveToTrash,
            "includeCLI": includeCLI,
            "includeApps": includeApps,
            "collectCrashLogs": collectCrashLogs,
            "projectRoots": projectRoots,
            // nil is stored as an absent key (plists have no null)
            "generalSelectedRows": generalSelectedRows.map { Array($0) } ?? [],
            "showMenuBarCPU": showMenuBarCPU,
            "showMenuBarMemory": showMenuBarMemory,
            "showMenuBarTemperature": showMenuBarTemperature,
            "showMenuBarLogo": showMenuBarLogo,
            "showDesktopStats": showDesktopStats,
            "launchAtLogin": launchAtLogin,
        ])
        // Broadcast to the tray agent: its VM re-reads once, so setting
        // changes take effect on the panel and menu bar labels
        // immediately, without waiting for an agent restart.
        AppBridge.postSettingsChanged()
    }

    /// Re-reads shared settings. Called by the agent after receiving a
    /// settings-changed broadcast.
    func reloadSettings() {
        loadSettings()
    }

    /// Toggles crash-log collection. Persists the choice and applies it in
    /// this process immediately — arming or disarming the handlers needs no
    /// restart. The other process catches up through the settings-changed
    /// broadcast, the same path every other setting travels.
    func setCrashLogCollection(_ enabled: Bool) {
        guard collectCrashLogs != enabled else { return }
        collectCrashLogs = enabled
        saveSettings()
        crashCollectionApply(enabled)
    }

    /// Toggle launch-at-login. Both register / unregister are
    /// system-level operations; on failure, keep the original state and
    /// show a hint.
    func setLaunchAtLogin(_ enabled: Bool) {
        guard launchAtLogin != enabled else { return }
        Task {
            do {
                if enabled {
                    // Rebuild rather than plain register: a leftover entry from
                    // an older binary already satisfies "registered", so
                    // registering it again would leave the constraint that fails
                    // at every login in place.
                    try await LaunchAtLogin.repairIfNeeded(preferred: true)
                } else {
                    try await LaunchAtLogin.unregister()
                    LaunchAtLogin.clearRegistrationRecord()
                    // Unregistering a login item makes launchd kill the process
                    // it spawned for it, so the tray would vanish the moment the
                    // setting is turned off — yet the setting only ever decided
                    // whether the agent starts at login. Bring the agent back
                    // through LaunchServices, whose instances the login item has
                    // no hold on; a no-op when the running one survived.
                    AppBridge.ensureAgentRunning()
                }
                launchAtLogin = enabled
                saveSettings()
            } catch {
                showToast(.error, L10n.tr(enabled ? "toast.launchAtLoginOnFailed" : "toast.launchAtLoginOffFailed"))
            }
        }
    }

    func addProjectRoot(_ path: String) {
        let expanded = FileSystem.expand(path)
        guard !expanded.isEmpty, !projectRoots.contains(expanded) else { return }
        projectRoots.append(expanded)
        saveSettings()
    }

    func removeProjectRoot(_ path: String) {
        projectRoots.removeAll { $0 == path }
        saveSettings()
    }

    // MARK: - Project Directory Scanning

    /// Scans custom project directories and merges the results into the
    /// list.
    ///
    /// Processes each root and merges immediately, rather than
    /// accumulating results from all roots together: this way peak memory
    /// depends only on a single root's output, and the sidebar can update
    /// progressively.
    func scanProjectRoots() async {
        guard !projectRoots.isEmpty else { return }
        let names = ScanOptions(projectRoots: projectRoots).projectJunkNames

        for root in projectRoots {
            if Task.isCancelled { return }
            progressLabel = L10n.fmt("scan.projectRoot", root)

            let startedAt = ContinuousClock.now
            // Discovery and measurement complete in the same detached
            // task: if measurement stayed on the main thread, the
            // synchronous traversal of each artifact directory would block
            // the UI (same reason as scanAppJunk).
            let measured = await Task.detached(priority: .utility) {
                let discovered = ScanEngine.scanProjectJunk(root: root, names: names, maxDepth: 8)
                return await ScanEngine.measure(discovered)
            }.value
            guard !measured.isEmpty else {
                MackitLog.scan.info("project root has no artifacts: \(root, privacy: .public)")
                continue
            }
            MackitLog.scan.info("project root found \(measured.count, privacy: .public) artifact directories: \(root, privacy: .public), took \(MackitLog.duration(.now - startedAt), privacy: .public)")

            // Roots may be nested inside each other (e.g. ~/Projects and
            // ~/Projects/foo), so the same build artifact directory may be
            // found more than once; mergeDiscovered deduplicates by id.
            mergeDiscovered(measured)
        }
    }

    // MARK: - App Junk Scanning

    /// Enumerates the regenerable junk installed apps leave behind (caches,
    /// HTTP storages, WebKit data, logs, crash reports), merging the results
    /// into the general module's app-junk row.
    ///
    /// Apps themselves are no longer part of the scan: uninstalling lives in
    /// the app uninstall tool (`AppUninstallModel`), which owns the bundles
    /// and the data residue. This scan deliberately produces junk entries
    /// only, so no app data is ever reachable from the cleanup scan.
    ///
    /// roots and home are injectable for testing. Size measurement is
    /// handed to `ScanEngine.measure`: it throttles internally against the
    /// same concurrency limit, and the engine manages the bookkeeping of
    /// intra-batch concurrency and inter-batch serialization.
    func scanAppJunk(roots: [String] = AppScanner.defaultRoots, home: String = NSHomeDirectory()) async {
        progressLabel = L10n.tr("scan.apps")

        // Discovery and measurement are placed in the same detached task:
        // task group child tasks inherit the caller's actor isolation, and
        // doing synchronous directory traversals one by one on the main
        // thread would freeze the UI (measured: 127 items took 60
        // seconds). After detaching, measurement runs on the cooperation
        // thread pool, throttled by ScanEngine's semaphore.
        let measured = await Task.detached(priority: .utility) {
            let discovered = AppScanner.scanAppJunk(roots: roots, home: home)
            return await ScanEngine.measure(discovered)
        }.value
        if Task.isCancelled { return }
        guard !measured.isEmpty else {
            MackitLog.apps.info("app junk scan: no regenerable app junk found")
            return
        }
        MackitLog.apps.info("app junk scan: \(measured.count, privacy: .public) entries")

        mergeDiscovered(measured)
    }

    // MARK: - Language File Scanning

    /// Enumerates useless localization directories inside installed apps,
    /// merging the results into the list.
    ///
    /// Same detached-task shape as `scanAppJunk`: discovery walks every app
    /// bundle's Resources directory, which must not run on the main thread.
    func scanLanguageFiles() async {
        progressLabel = L10n.tr("scan.languageFiles")

        let measured = await Task.detached(priority: .utility) {
            let discovered = LanguageFileScanner.scanLanguageFiles()
            return await ScanEngine.measure(discovered)
        }.value
        if Task.isCancelled { return }
        guard !measured.isEmpty else {
            MackitLog.scan.info("language packs scan: no cleanable language packs found")
            return
        }
        MackitLog.scan.info("language packs scan: found \(measured.count, privacy: .public) language pack directories")

        mergeDiscovered(measured)
    }

    // MARK: - Downloads Scanning

    /// Enumerates installers and archives in the Downloads folder, merging
    /// the results into the list. Items are `.caution`, so they never join a
    /// default selection and always pass through the confirmation sheet.
    func scanDownloads() async {
        progressLabel = L10n.tr("scan.downloads")

        let measured = await Task.detached(priority: .utility) {
            let discovered = DownloadsScanner.scanDownloads()
            return await ScanEngine.measure(discovered)
        }.value
        if Task.isCancelled { return }
        guard !measured.isEmpty else {
            MackitLog.scan.info("downloads scan: no installers or archives found")
            return
        }
        MackitLog.scan.info("downloads scan: found \(measured.count, privacy: .public) installers or archives")

        mergeDiscovered(measured)
    }

    /// Merges a batch of new items into the list, deduplicating by id
    /// (shared by project scanning, app junk scanning, and the other
    /// scanners). Visible within the module so tests can drive it directly.
    func mergeDiscovered(_ fresh: [JunkItem]) {
        guard !fresh.isEmpty else { return }
        let existing = Set(items.map(\.id))
        // Path-level dedup on top of the id dedup: two rules can target the
        // same path — an app's log directory is both an app-junk entry of
        // the app junk scan and a child of the user-logs rule, and the same
        // bytes must never be counted (or shown) twice. First one wins; the
        // static rules stream in before the app junk scan, so the generic
        // rule owns the path and the junk scan simply doesn't re-list it.
        var seenPaths = Set(items.map(\.path))
        // The same bytes are also double-counted when one entry *contains*
        // another: Homebrew's cache directory is a single app-junk entry
        // while the brew rule lists each download inside it. The coarser
        // entry is the one that loses — the finer entries stay, so nothing
        // disappears from the list that was not already covered.
        let listedPaths = items.map(\.path)
        var unique: [JunkItem] = []
        for item in fresh where !existing.contains(item.id) && !item.path.isEmpty {
            guard seenPaths.insert(item.path).inserted else { continue }
            guard !containsListed(item.path, in: listedPaths) else { continue }
            unique.append(item)
        }
        guard !unique.isEmpty else { return }

        items.append(contentsOf: unique)
        applyDefaultSelection(unique)
        itemsDidChange()
        publishMenuSnapshot()
    }

    /// Whether any already-listed entry sits inside `path` — i.e. whether
    /// cleaning `path` would also delete entries the list already shows
    /// separately.
    private func containsListed(_ path: String, in listedPaths: [String]) -> Bool {
        let prefix = path + "/"
        return listedPaths.contains { $0.hasPrefix(prefix) }
    }

    // MARK: - App Icons

    /// Gets the icon by .app path, with caching. The memory ranking reads
    /// this one; the uninstall tool keeps its own cache inside its model.
    ///
    /// The cache is excluded from Observation: if filling the cache during
    /// first render triggered a view update, it would add a pointless
    /// extra round of body recomputation.
    @ObservationIgnored private var appIconCache: [String: NSImage] = [:]

    func appIcon(forPath path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        if let cached = appIconCache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        appIconCache[path] = icon
        return icon
    }
}

/// One state snapshot of the menu bar panel.
///
/// `MenuBarExtra`'s menu content is hosted by SwiftUI into an `NSMenu`,
/// and any change in dependencies rebuilds the menu items. During a scan,
/// `progressFraction` / `items` / `selection` change at a per-work-unit
/// cadence, so having the menu read them directly would make it flicker
/// continuously when open; it therefore depends only on this snapshot,
/// refreshed by `AppViewModel.publishMenuSnapshot` at a fixed interval.
struct MenuBarSnapshot: Equatable {
    var phase: AppViewModel.ScanPhase = .idle
    var cleanPhase: AppViewModel.CleanPhase = .idle
    /// Scan progress percentage, 0–100.
    var percent: Int = 0
    var totalSize: Int64 = 0
    var itemCount: Int = 0
    var selectedCount: Int = 0
    var selectedSize: Int64 = 0
    /// System stats sample; the tray menu's CPU / memory / temperature
    /// rows read from here.
    ///
    /// Sharing one snapshot with the scan state, it likewise benefits from
    /// the "suspend publishing during menu tracking" protection:
    /// monitoring numbers change every two seconds, but while a menu is
    /// open, not a single rebuild happens.
    var stats: SystemStats = SystemStats()
    /// The few apps using the most memory; the panel's ranking reads from
    /// here.
    var topApps: [AppMemoryEntry] = []
    /// CPU usage history, newest last; the panel's graph reads from here.
    var cpuHistory: [Double] = []
}

/// Sort presets: the toolbar menu's options.
///
/// Every "field × direction" combination produced by header clicks has a
/// corresponding item here, so a menu selection never ends up matching
/// none of the current sort options; the actual sort state is a
/// `JunkItemComparator`.
enum ItemSort: String, CaseIterable, Identifiable {
    case sizeDescending
    case sizeAscending
    case nameAscending
    case nameDescending
    case dateDescending
    case dateAscending

    var id: String { rawValue }

    var title: String {
        L10n.tr("sort.\(rawValue)")
    }

    var comparator: JunkItemComparator {
        switch self {
        case .sizeDescending: JunkItemComparator(field: .size, order: .reverse)
        case .sizeAscending: JunkItemComparator(field: .size, order: .forward)
        case .nameAscending: JunkItemComparator(field: .name, order: .forward)
        case .nameDescending: JunkItemComparator(field: .name, order: .reverse)
        case .dateDescending: JunkItemComparator(field: .modified, order: .reverse)
        case .dateAscending: JunkItemComparator(field: .modified, order: .forward)
        }
    }

    /// The preset a comparator came from — how the toolbar names the sort in
    /// force instead of a fixed label.
    ///
    /// Needed because `sortComparator` is written by the table's header
    /// clicks as well as by the menu, so the current state is a comparator,
    /// not a preset. Every comparator a header click can produce (three
    /// fields × two directions) is one of these six, which is why the
    /// round trip is total in practice; the initializer stays failable so a
    /// future field has to be given a preset rather than silently reporting
    /// the wrong sort's name.
    init?(comparator: JunkItemComparator) {
        guard let match = Self.allCases.first(where: { $0.comparator == comparator }) else {
            return nil
        }
        self = match
    }
}

/// Top banner.
struct Banner: Equatable, Identifiable {
    /// How long a toast stays up before it dismisses itself. One definition
    /// shared by the view model's timer and the toast's countdown hairline,
    /// so the bar and the dismissal cannot drift apart.
    static let autoDismissSeconds: TimeInterval = 3.5

    enum Style: Equatable {
        case info, success, error

        /// The name used for inter-process passing (the agent → main app
        /// notice command).
        var wireName: String {
            switch self {
            case .info: return "info"
            case .success: return "success"
            case .error: return "error"
            }
        }

        /// Restored from the wire name; unknown names are treated as info,
        /// so the hint is not lost.
        static func from(wireName: String) -> Style {
            switch wireName {
            case "success": return .success
            case "error": return .error
            default: return .info
            }
        }

        /// Filled variants: the toast shows these in a small chip, where an
        /// outlined glyph's stroke thins out and the mark reads as a smudge.
        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .error: return "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .info: return .blue
            case .success: return .green
            case .error: return .orange
            }
        }
    }

    let style: Style
    let message: String
    /// When the toast was raised; anchors the countdown hairline. Defaulted
    /// rather than required so raising the same message twice — which reuses
    /// the toast's identity and would keep a stale appearance time — still
    /// gets a fresh anchor.
    let shownAt: Date = Date()

    var id: String { "\(style)-\(message)" }
}
