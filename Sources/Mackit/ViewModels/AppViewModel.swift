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

    /// Row selection set, consistent with the list checkmarks.
    var selection: Set<String> = []

    /// Cleanup result summary.
    var lastReclaimed: Int64 = 0
    var lastFailures: Int = 0
    var cleanOutcomes: [CleanOutcome] = []
    var cleanCurrentTitle: String = ""
    var cleanProgress: Double = 0

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
    /// Whether installed apps are enumerated in the main scan (the "Apps"
    /// category).
    var includeApps: Bool = true
    var projectRoots: [String] = []
    /// Whether launch-at-login is registered. The real state lives in the
    /// system login items, synced over at startup.
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
    init(statsPolling: Bool = true) {
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
    private func beginCleanFromRemote() {
        if selection.isEmpty {
            selectAllSafe()
        }
        requestClean()
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
            selectedSize: selectedSize
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
        hardwareProfile = HardwareSampler.profile()
    }

    /// "Disk space analysis" on the hardware page: run a scan so the list
    /// enumerates the space-occupying items one by one, while leaving the
    /// hardware page to return to the list — a bare total offers no next
    /// step.
    func analyzeDiskSpace() {
        showsHardware = false
        selectedCategory = nil
        startScan()
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
        MackitLog.system.info("释放内存：请求授权")
        Task { [weak self] in
            let outcome = MemoryReleaser.release(
                run: MemoryReleaser.run,
                memoryFree: { SystemStatsSampler.memoryUsage()?.free }
            )

            let style: Banner.Style
            let message: String
            switch outcome {
            case .released(let freed):
                MackitLog.system.info("释放内存完成：\(freed, privacy: .public) 字节")
                style = .success
                message = L10n.fmt("toast.memoryReleased", Formatters.bytes(freed))
            case .noChange:
                MackitLog.system.info("释放内存：空闲量无变化")
                style = .info
                message = L10n.tr("toast.memoryReleasedNone")
            case .cancelled:
                MackitLog.system.info("释放内存：用户在授权对话框取消")
                style = .info
                message = L10n.tr("toast.memoryReleasedCancelled")
            case .failed(let detail):
                MackitLog.system.error("释放内存失败：\(detail, privacy: .public)")
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
        let safeOnly: Bool
        let search: String
        let sort: JunkItemComparator
    }

    private struct StatsKey: Equatable {
        let items: Int
        let selection: Int
    }

    private struct CategoryStats {
        let totals: [JunkCategory: Int64]
        let counts: [JunkCategory: Int]
        let totalSize: Int64
    }

    private struct SelectionStats {
        let size: Int64
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

    var totalSize: Int64 { categoryStats.totalSize }

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

    var selectedItems: [JunkItem] { selectionStats.items }

    /// The highest risk level among the selected items, used for the
    /// warning style of the confirmation dialog.
    var selectedMaxRisk: RiskLevel { selectionStats.maxRisk }

    private var selectionStats: SelectionStats {
        let key = StatsKey(items: itemsRevision, selection: selectionRevision)
        if let cached = selectionCache, cached.key == key { return cached.value }
        var size: Int64 = 0
        var maxRisk: RiskLevel?
        var selected: [JunkItem] = []
        selected.reserveCapacity(selection.count)
        for item in items where selection.contains(item.id) {
            size += item.size
            if let current = maxRisk, item.risk > current { maxRisk = item.risk }
            else if maxRisk == nil { maxRisk = item.risk }
            selected.append(item)
        }
        let value = SelectionStats(size: size, items: selected, maxRisk: maxRisk ?? .safe)
        selectionCache = (key, value)
        return value
    }

    /// Filters in a single pass, then sorts by the current sort mode.
    /// Search matching uses item.searchBlob (the whole text lowercased at
    /// creation time), avoiding three lowercased() calls per item on every
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
        selection = []
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
        MackitLog.scan.info("扫描开始：项目根 \(self.projectRoots.count, privacy: .public) 个，CLI \(self.includeCLI, privacy: .public)，应用发现 \(self.includeApps, privacy: .public)")

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
                MackitLog.scan.info("规则扫描阶段完成：\(self.items.count, privacy: .public) 项，耗时 \(MackitLog.duration(.now - startedAt), privacy: .public)")
            }

            // App discovery comes before project directories: it always
            // enumerates two directories, is quick and predictable, letting
            // the "Apps" category appear as early as possible; project
            // roots can be very large, so they go last.
            if self.includeApps {
                await self.scanApps()
            }
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
                self.selectAllSafe()
                self.requestClean()
            }
            if let startedAt = self.scanStartedAt {
                let elapsed = MackitLog.duration(.now - startedAt)
                MackitLog.scan.info("扫描完成：\(self.items.count, privacy: .public) 项，合计 \(self.totalSize, privacy: .public) 字节，耗时 \(elapsed, privacy: .public)")
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

    private func applyDefaultSelection(_ batch: [JunkItem]) {
        // The none tier has no items eligible for auto-checking
        guard let cap = autoSelectRisk.riskCap else { return }
        var changed = false
        for item in batch where item.risk <= cap && !item.isUnknownSize {
            selection.insert(item.id)
            changed = true
        }
        if changed { selectionDidChange() }
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
            MackitLog.scan.info("扫描被用户取消：已发现 \(self.items.count, privacy: .public) 项，耗时 \(MackitLog.duration(.now - startedAt), privacy: .public)")
            scanStartedAt = nil
        }
        publishMenuSnapshot(force: true)
    }

    // MARK: - Selection

    func toggle(_ item: JunkItem) {
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
        selectionDidChange()
        publishMenuSnapshot(force: true)
    }

    func selectAllVisible() {
        for item in visibleItems {
            selection.insert(item.id)
        }
        selectionDidChange()
        publishMenuSnapshot(force: true)
    }

    func deselectAllVisible() {
        for item in visibleItems {
            selection.remove(item.id)
        }
        selectionDidChange()
        publishMenuSnapshot(force: true)
    }

    func selectAllSafe() {
        for item in items where item.risk == .safe {
            selection.insert(item.id)
        }
        selectionDidChange()
        publishMenuSnapshot(force: true)
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
        if cleanPhase == .done { dismissCleanResult() }
    }

    func isSelected(_ item: JunkItem) -> Bool { selection.contains(item.id) }

    // MARK: - Cleanup

    func requestClean() {
        guard !selection.isEmpty else { return }
        // Cleaning must go through list confirmation first. There is
        // deliberately no "skip confirmation" toggle here: the cost of
        // mistakenly deleting caches/archives far outweighs clicking the
        // button one more time.
        cleanPhase = .confirming
        publishMenuSnapshot(force: true)
    }

    /// Cancel confirmation, returning to idle.
    func cancelConfirmation() {
        cleanPhase = .idle
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
        MackitLog.clean.info("清理开始：\(self.selectedItems.count, privacy: .public) 项，合计 \(self.selectedSize, privacy: .public) 字节，移入废纸篓 \(self.moveToTrash, privacy: .public)")

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
                MackitLog.clean.info("清理完成：释放 \(reclaimed, privacy: .public) 字节，失败 \(failures, privacy: .public) 项，耗时 \(MackitLog.duration(.now - startedAt), privacy: .public)")
                cleanStartedAt = nil
            }
            for outcome in cleanOutcomes where !outcome.succeeded {
                MackitLog.clean.error("清理失败「\(outcome.title, privacy: .public)」：\(outcome.message, privacy: .public)")
            }

            // Cleanup results are reported via Toast; the failure count
            // must appear in the hint, so the user does not only see
            // "success" and miss the failures.
            if failures == 0 {
                showToast(.success, L10n.fmt("toast.reclaimed", Formatters.bytes(reclaimed)))
            } else {
                showToast(.error, L10n.fmt(
                    failures == 1 ? "toast.reclaimedWithFailures.one" : "toast.reclaimedWithFailures.other",
                    Formatters.bytes(reclaimed), failures
                ))
            }

            // Remove in one batch, triggering only one cache invalidation
            if !pendingRemoval.isEmpty {
                items.removeAll { pendingRemoval.contains($0.id) }
                selection.subtract(pendingRemoval)
                itemsDidChange()
                selectionDidChange()
            }
            pendingRemoval = []
            publishMenuSnapshot(force: true)
        }
    }

    private func removeItem(id: String) {
        items.removeAll { $0.id == id }
        selection.remove(id)
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
            items.removeAll { pendingRemoval.contains($0.id) }
            selection.subtract(pendingRemoval)
            itemsDidChange()
            selectionDidChange()
            pendingRemoval = []
            MackitLog.clean.info("清理被用户取消：已完成的 \(alreadyRemoved, privacy: .public) 项已从清单移除")
        } else {
            MackitLog.clean.info("清理被用户取消：尚无已完成的项")
        }
        cleanOutcomes = []
        cleanProgress = 0
        cleanCurrentTitle = ""
        cleanStartedAt = nil
        cleanPhase = .idle
        publishMenuSnapshot(force: true)
    }

    // MARK: - Operation Hints (Toast)

    /// Pops an operation hint, auto-dismissed after 3.5 seconds.
    /// A new hint cancels the previous one's timer task, so hints are not
    /// cleared prematurely during rapid successive operations.
    func showToast(_ style: Banner.Style, _ message: String) {
        bannerDismissTask?.cancel()
        banner = Banner(style: style, message: message)

        bannerDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
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

    func revealInFinder(_ item: JunkItem) {
        guard !item.path.isEmpty else { return }
        let url = URL(fileURLWithPath: item.path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
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

    func copyPath(_ item: JunkItem) {
        let text = item.path.isEmpty ? item.command.joined(separator: " ") : item.path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func trashSingle(_ item: JunkItem) {
        guard !item.path.isEmpty else { return }
        let url = URL(fileURLWithPath: item.path)
        guard !FileSystem.isProtected(url.path) else {
            showToast(.error, L10n.tr("toast.protectedPath"))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let recycled = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                NSWorkspace.shared.recycle([url]) { newURLs, error in
                    let succeeded = error == nil && !newURLs.isEmpty
                    continuation.resume(returning: succeeded)
                }
            }
            if !recycled {
                self.showToast(.error, L10n.tr("toast.trashFailed"))
            } else {
                self.removeItem(id: item.id)
                self.volumeUsage = .home()
                self.showToast(.success, L10n.fmt("toast.trashed", item.title))
            }
        }
    }

    // MARK: - Settings Persistence

    private func loadSettings() {
        // The two processes (main app and tray agent) each hold a VM, and
        // settings live in a shared file, so a change on one side becomes
        // visible to the other.
        let values = SharedStore.loadSettings()
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
        projectRoots = values["projectRoots"] as? [String] ?? []
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
        if let value = values["showDesktopStats"] as? Bool {
            showDesktopStats = value
        }
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    func saveSettings() {
        // Only write the keys this VM is responsible for; SharedStore
        // merges with the other keys in the file and replaces wholesale.
        SharedStore.saveSettings([
            "autoSelectRisk": autoSelectRisk.rawValue,
            "moveToTrash": moveToTrash,
            "includeCLI": includeCLI,
            "includeApps": includeApps,
            "projectRoots": projectRoots,
            "showMenuBarCPU": showMenuBarCPU,
            "showMenuBarMemory": showMenuBarMemory,
            "showMenuBarTemperature": showMenuBarTemperature,
            "showDesktopStats": showDesktopStats,
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

    /// Toggle launch-at-login. Both register / unregister are
    /// system-level operations; on failure, keep the original state and
    /// show a hint.
    func setLaunchAtLogin(_ enabled: Bool) {
        guard launchAtLogin != enabled else { return }
        Task {
            do {
                if enabled {
                    try LaunchAtLogin.register()
                } else {
                    try await LaunchAtLogin.unregister()
                }
                launchAtLogin = enabled
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
            // the UI (same reason as scanApps).
            let measured = await Task.detached(priority: .utility) {
                let discovered = ScanEngine.scanProjectJunk(root: root, names: names, maxDepth: 8)
                return await ScanEngine.measure(discovered)
            }.value
            guard !measured.isEmpty else {
                MackitLog.scan.info("项目根无产物：\(root, privacy: .public)")
                continue
            }
            MackitLog.scan.info("项目根发现 \(measured.count, privacy: .public) 个产物目录：\(root, privacy: .public)，耗时 \(MackitLog.duration(.now - startedAt), privacy: .public)")

            // Roots may be nested inside each other (e.g. ~/Projects and
            // ~/Projects/foo), so the same build artifact directory may be
            // found more than once; mergeDiscovered deduplicates by id.
            mergeDiscovered(measured)
        }
    }

    // MARK: - App Scanning

    /// Enumerates installed apps and their residue files, merging the
    /// results into the list.
    ///
    /// roots and home are injectable for testing. Size measurement is
    /// handed to `ScanEngine.measure`: it throttles internally against the
    /// same concurrency limit, and the engine manages the bookkeeping of
    /// intra-batch concurrency and inter-batch serialization.
    func scanApps(roots: [String] = AppScanner.defaultRoots, home: String = NSHomeDirectory()) async {
        progressLabel = L10n.tr("scan.apps")

        // Discovery and measurement are placed in the same detached task:
        // task group child tasks inherit the caller's actor isolation, and
        // doing synchronous directory traversals one by one on the main
        // thread would freeze the UI (measured: 127 items took 60
        // seconds). After detaching, measurement runs on the cooperation
        // thread pool, throttled by ScanEngine's semaphore.
        let measured = await Task.detached(priority: .utility) {
            let discovered = AppScanner.scanApps(roots: roots, home: home)
            return await ScanEngine.measure(discovered)
        }.value
        if Task.isCancelled { return }
        guard !measured.isEmpty else {
            MackitLog.apps.info("应用发现：未找到任何已安装应用")
            return
        }
        let bundleCount = measured.filter { $0.appKind == .bundle }.count
        MackitLog.apps.info("应用发现：\(bundleCount, privacy: .public) 个应用，\(measured.count, privacy: .public) 条条目")

        mergeDiscovered(measured)
    }

    /// Merges a batch of new items into the list, deduplicating by id
    /// (shared by project scanning and app scanning). Visible within the
    /// module so tests can drive it directly.
    func mergeDiscovered(_ fresh: [JunkItem]) {
        guard !fresh.isEmpty else { return }
        let existing = Set(items.map(\.id))
        let unique = fresh.filter { !existing.contains($0.id) }
        guard !unique.isEmpty else { return }

        items.append(contentsOf: unique)
        applyDefaultSelection(unique)
        itemsDidChange()
        publishMenuSnapshot()
    }

    // MARK: - App Uninstall

    /// All residue file entries of a given app bundle.
    private func residueItems(bundleID: String) -> [JunkItem] {
        items.filter { $0.appKind?.isResidue == true && $0.bundleID == bundleID }
    }

    /// All residue file entry ids of a given app bundle.
    func residueIDs(for item: JunkItem) -> [String] {
        guard item.appKind == .bundle, let bundleID = item.bundleID else { return [] }
        return residueItems(bundleID: bundleID).map(\.id)
    }

    /// Uninstall an app: check the bundle itself and all residue files,
    /// entering cleanup confirmation directly.
    func uninstallApp(_ item: JunkItem) {
        guard item.appKind == .bundle else { return }
        var next: Set<String> = [item.id]
        next.formUnion(residueIDs(for: item))
        selection = next
        selectionDidChange()
        requestClean()
    }

    /// Only clean an app's residue files, keeping the app bundle itself.
    func selectAppResidues(_ item: JunkItem) {
        guard item.appKind == .bundle else { return }
        let next = Set(residueIDs(for: item))
        guard !next.isEmpty else { return }
        selection = next
        selectionDidChange()
        requestClean()
    }

    /// Whether the selected items contain an app bundle (the confirmation
    /// panel switches uninstall wording accordingly).
    var hasSelectedApps: Bool {
        selectedItems.contains { $0.appKind == .bundle }
    }

    /// Apps whose bundle is checked but whose related files are not yet
    /// all checked, one entry per app.
    ///
    /// When only the app's row is checked in the table and clean is
    /// clicked, files like caches and application support are silently left
    /// on disk; the confirmation panel warns accordingly and offers a
    /// "select all" one-click fix.
    ///
    /// The computation is O(items × apps), likewise cached by revision,
    /// and not re-run on every body evaluation.
    @ObservationIgnored private var unselectedResiduesCache: (key: (Int, Int), value: [AppResidueSummary])?

    var unselectedAppResidues: [AppResidueSummary] {
        let key = (itemsRevision, selectionRevision)
        if let cached = unselectedResiduesCache, cached.key == key { return cached.value }
        var summaries: [AppResidueSummary] = []
        var seen: Set<String> = []
        for item in selectedItems where item.appKind == .bundle {
            guard let bundleID = item.bundleID, !seen.contains(bundleID) else { continue }
            seen.insert(bundleID)
            let pending = residueItems(bundleID: bundleID).filter { !selection.contains($0.id) }
            guard !pending.isEmpty else { continue }
            summaries.append(
                AppResidueSummary(
                    appName: item.title,
                    count: pending.count,
                    size: pending.reduce(0) { $0 + $1.size }
                )
            )
        }
        unselectedResiduesCache = (key, summaries)
        return summaries
    }

    /// Adds all related files of the selected apps into the selection (the
    /// confirmation panel's one-click action).
    func selectResiduesForSelectedApps() {
        var next = selection
        for item in selectedItems where item.appKind == .bundle {
            guard let bundleID = item.bundleID else { continue }
            next.formUnion(residueItems(bundleID: bundleID).map(\.id))
        }
        guard next != selection else { return }
        selection = next
        selectionDidChange()
    }

    /// Names of the selected apps that are currently running. Uninstalling
    /// them will be refused by the clean engine, so they are listed here
    /// in advance in the confirmation panel, sparing the user a wasted
    /// trip.
    ///
    /// `runningApplications` is one workspace XPC query, and the
    /// confirmation panel's list reads this property on every scroll /
    /// recompute; cached by items/selection revision, so only one query
    /// per confirmation.
    @ObservationIgnored private var runningAppsCache: (key: (Int, Int), value: [String])?

    var runningAppNames: [String] {
        let key = (itemsRevision, selectionRevision)
        if let cached = runningAppsCache, cached.key == key { return cached.value }
        let running = NSWorkspace.shared.runningApplications
        let value = selectedItems
            .filter { $0.appKind == .bundle }
            .filter { item in
                guard let bundleID = item.bundleID else { return false }
                return running.contains { $0.bundleIdentifier == bundleID }
            }
            .map(\.title)
        runningAppsCache = (key, value)
        return value
    }

    /// The real icon of an app bundle; returns nil for non-app items, and
    /// the view falls back to a category symbol.
    ///
    /// The cache is excluded from Observation: if filling the cache during
    /// first render triggered a view update, it would add a pointless
    /// extra round of body recomputation.
    @ObservationIgnored private var appIconCache: [String: NSImage] = [:]

    func icon(for item: JunkItem) -> NSImage? {
        guard item.appKind == .bundle, !item.path.isEmpty else { return nil }
        return appIcon(forPath: item.path)
    }

    /// Gets the icon by .app path, with caching. Cleanup items and the
    /// memory ranking share one cache: when the same app appears in both
    /// places, NSWorkspace is queried only once.
    func appIcon(forPath path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        if let cached = appIconCache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        appIconCache[path] = icon
        return icon
    }
}

/// A summary of the related files of a checked app that are not yet
/// checked.
struct AppResidueSummary: Equatable, Hashable, Sendable {
    let appName: String
    let count: Int
    let size: Int64
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
}

/// Top banner.
struct Banner: Equatable, Identifiable {
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

        var symbol: String {
            switch self {
            case .info: return "info.circle"
            case .success: return "checkmark.circle"
            case .error: return "exclamationmark.triangle"
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

    var id: String { "\(style)-\(message)" }
}
