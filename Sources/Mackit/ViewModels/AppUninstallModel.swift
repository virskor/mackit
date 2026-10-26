import Foundation
import AppKit

/// State model for the app uninstall tool page.
///
/// The tool owns the whole uninstall flow the cleanup scan used to carry:
/// enumerating installed apps and their residue, letting the user pick an app
/// (and, expanded, its individual leftover files), and running the removal
/// through the same `CleanEngine` the cleanup scan uses — including the
/// "app is running" refusal and the move-to-Trash preference, which the page
/// passes in from the shared setting rather than owning a second copy of.
///
/// Every dependency is an injected closure so the page's contracts are
/// testable without a real /Applications or ~/Library; the defaults are the
/// real ones. The snapshot survives page switches like the other tools'
/// (the scan belongs to the session, not to the page being visible), and a
/// rescan is the only thing that re-enumerates.
@MainActor
@Observable
final class AppUninstallModel {
    /// One installed app with the residue entries found for it.
    struct AppEntry: Identifiable, Sendable {
        let bundle: JunkItem
        /// The app's leftover files, largest first — the order the expanded
        /// row lists them in.
        let residues: [JunkItem]

        var id: String { bundle.id }
        var name: String { bundle.title }
        var bundleID: String { bundle.bundleID ?? "" }
        /// The app bundle plus every leftover file: what uninstalling the app
        /// completely would remove.
        var totalSize: Int64 { bundle.size + residues.reduce(0) { $0 + $1.size } }

        /// Every item the entry covers, bundle first.
        var allIDs: [String] { [bundle.id] + residues.map(\.id) }
    }

    /// The page's state machine. Kept private to the model so the sheet, the
    /// overlay and the result card are all driven from one place.
    enum Phase: Equatable {
        case idle
        case confirming
        case cleaning
        case done
    }

    // MARK: Scanned data

    private(set) var apps: [AppEntry] = [] {
        didSet { stateRevision += 1 }
    }
    private(set) var isLoading = false
    /// Whether a scan has landed at least once. `activate` uses it to scan
    /// only on the session's first visit.
    private(set) var hasScanned = false

    // MARK: Selection

    /// Item ids the user has checked — app bundles and individual residue
    /// files alike. The tool's own selection: the cleanup scan's
    /// `CleanupSelection` belongs to the scan, and an uninstall gesture must
    /// never move what a scan pre-checked.
    ///
    /// The observer bumps `stateRevision`, the key the derived-data caches
    /// below are invalidated by — every mutation goes through this property
    /// or through `apps`, so neither cache can go stale.
    var selectedIDs: Set<String> = [] {
        didSet { stateRevision += 1 }
    }

    /// The apps matching the search field, name and bundle ID.
    var searchText: String = ""

    // MARK: Clean state

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var currentTitle: String = ""
    private(set) var outcomes: [CleanOutcome] = []
    /// How many of the reported outcomes succeeded. Failed items also went
    /// into `outcomes`; counting all of them would describe failures as
    /// "cleaned". Maintained per event so the overlay does not re-filter the
    /// whole list on every step.
    private(set) var cleanedCount = 0
    private(set) var reclaimed: Int64 = 0
    private(set) var failures = 0
    /// Whether the finished clean moved anything to the Trash: those bytes
    /// are not back on the volume yet, so the result card says "moved out"
    /// rather than claiming them as released.
    private(set) var movedToTrash = false

    // MARK: Dependencies

    /// Discovers apps and their residue, measured. Runs off the main thread
    /// by its default implementation — enumerating /Applications and probing
    /// ~/Library is seconds of IO.
    private let scan: () async -> [JunkItem]
    /// Removes the given items, reporting each outcome.
    private let clean: ([JunkItem], Bool) -> AsyncStream<CleanEvent>
    /// Whether the app with this bundle ID is running.
    private let isAppRunning: @MainActor @Sendable (String) -> Bool
    /// The real icon of an app bundle path.
    private let iconForPath: @MainActor (String) -> NSImage?

    private var scanTask: Task<Void, Never>?
    private var cleanTask: Task<Void, Never>?

    /// Item ids pending removal. One is recorded for each successful clean,
    /// and all are dropped from the list in one batch at the end — the same
    /// batching the cleanup scan uses, for the same reason: removing them one
    /// by one is O(n) per item.
    private var pendingRemoval: Set<String> = []

    /// When the running clean started; its duration is logged on finish.
    private var cleanStartedAt: ContinuousClock.Instant?

    /// The app-icon cache. Excluded from Observation: filling it during a
    /// render would add a pointless extra round of body recomputation.
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]

    /// Bumped whenever the scanned list or the selection changes; the key the
    /// derived-data caches below are invalidated by. Writing it is
    /// deliberately excluded from Observation: it is a cache key, not state a
    /// view reads.
    @ObservationIgnored private var stateRevision = 0
    /// `NSWorkspace.runningApplications` is one workspace XPC query, and the
    /// confirmation sheet's body reads this on every evaluation; cached by
    /// revision so one confirmation costs one query, the same protection the
    /// cleanup scan's confirmation panel had.
    @ObservationIgnored private var runningAppsCache: (key: Int, value: [String])?
    /// O(apps × residue) per computation; likewise cached by revision so the
    /// sheet's several reads per body evaluation share one pass.
    @ObservationIgnored private var unselectedResiduesCache: (key: Int, value: [AppResidueSummary])?

    init(
        scan: @escaping @MainActor () async -> [JunkItem] = {
            // Discovery and measurement share one detached task, the same
            // shape the cleanup scan's app phase used: synchronous directory
            // traversal on the main thread would freeze the UI, and
            // measurement throttles itself inside ScanEngine.
            await Task.detached(priority: .utility) {
                let discovered = AppScanner.scanApps()
                return await ScanEngine.measure(discovered)
            }.value
        },
        clean: @escaping @MainActor ([JunkItem], Bool) -> AsyncStream<CleanEvent> = { items, moveToTrash in
            CleanEngine.clean(items: items, moveToTrash: moveToTrash)
        },
        isAppRunning: @escaping @MainActor @Sendable (String) -> Bool = CleanEngine.defaultAppRunningCheck,
        iconForPath: @escaping @MainActor (String) -> NSImage? = { NSWorkspace.shared.icon(forFile: $0) }
    ) {
        self.scan = scan
        self.clean = clean
        self.isAppRunning = isAppRunning
        self.iconForPath = iconForPath
    }

    // MARK: Lifecycle

    /// Called when the sidebar selects the tool. Scans once per session;
    /// coming back to a scanned list is instant.
    func activate() {
        guard !hasScanned, !isLoading else { return }
        rescan()
    }

    /// Re-enumerates the installed apps, replacing any in-flight scan.
    ///
    /// Checks for items that still exist survive: a rescan is usually run to
    /// see the effect of an uninstall, and throwing away the user's picks
    /// would make them redo the curation. Ids that no longer exist are
    /// dropped, so a removed app cannot stay checked as a ghost.
    func rescan() {
        // A rescan must never strand a running clean: the phase is the
        // overlay's and the footer's switch, and a clean left running under
        // an idle page would delete files the user can no longer see or stop.
        guard phase != .cleaning else { return }
        scanTask?.cancel()
        isLoading = true
        // A rescan while the confirmation sheet is up would empty the list
        // under it; the sheet is dismissed instead.
        phase = .idle
        // The previous clean's numbers are not this scan's: the result card
        // reads them, and a stale total would describe work that a cancel
        // threw away.
        reclaimed = 0
        failures = 0
        cleanedCount = 0
        movedToTrash = false
        outcomes = []
        let startedAt = ContinuousClock.now
        scanTask = Task { [scan] in
            let items = await scan()
            guard !Task.isCancelled else { return }
            self.isLoading = false
            self.hasScanned = true
            self.apps = Self.group(items)
            self.selectedIDs.formIntersection(Set(items.map(\.id)))
            MackitLog.apps.info("uninstall tool: \(self.apps.count, privacy: .public) apps, \(items.count, privacy: .public) entries, took \(MackitLog.duration(.now - startedAt), privacy: .public)")
        }
    }

    /// Groups a flat item list into per-app entries. Residue without its
    /// bundle cannot be uninstalled through the page and is left out — the
    /// scanner always emits the two together, so this only guards against a
    /// hand-built list.
    ///
    /// Bundles are keyed by item id, not bundle ID: the same app installed in
    /// both `/Applications` and `~/Applications` is two rows the user can
    /// uninstall one at a time, and both legitimately claim the same residue
    /// files. Checking both is still safe — the selection is a set of item
    /// ids, so each path is deleted once.
    static func group(_ items: [JunkItem]) -> [AppEntry] {
        var residuesByID: [String: [JunkItem]] = [:]
        for item in items where item.appKind?.isResidue == true {
            residuesByID[item.bundleID ?? "", default: []].append(item)
        }
        return items
            .filter { $0.appKind == .bundle }
            .map { bundle in
                AppEntry(
                    bundle: bundle,
                    residues: (residuesByID[bundle.bundleID ?? ""] ?? []).sorted { $0.size > $1.size }
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Derived data

    /// The apps the search field leaves, in list order.
    var visibleApps: [AppEntry] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return apps }
        // The bundle's search blob covers name, detail, path and bundle ID,
        // so searching "com.example" finds the app by its identifier.
        return apps.filter { $0.bundle.searchBlob.contains(needle) }
    }

    /// The checked items, in list order: each app's bundle first, then its
    /// checked residue files.
    var selectedItems: [JunkItem] {
        apps.flatMap { entry in
            (selectedIDs.contains(entry.bundle.id) ? [entry.bundle] : [])
                + entry.residues.filter { selectedIDs.contains($0.id) }
        }
    }

    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    /// How many app bundles are checked — the confirmation's "about to
    /// uninstall N apps" count. Residue rows don't count.
    var selectedAppCount: Int {
        apps.count { selectedIDs.contains($0.bundle.id) }
    }

    /// Whether every item of the app is checked (bundle and all residue),
    /// some are, or none are — the app row's tri-state checkbox.
    func selectionState(of entry: AppEntry) -> SelectionState {
        let checked = entry.allIDs.count { selectedIDs.contains($0) }
        if checked == 0 { return .none }
        return checked == entry.allIDs.count ? .all : .partial
    }

    enum SelectionState: Equatable {
        case none, partial, all
    }

    func isSelected(_ item: JunkItem) -> Bool { selectedIDs.contains(item.id) }

    /// Names of the checked apps that are currently running. Uninstalling
    /// them is refused by the clean engine, so the confirmation sheet lists
    /// them in advance, sparing the user a wasted trip.
    var runningAppNames: [String] {
        if let cached = runningAppsCache, cached.key == stateRevision { return cached.value }
        var seen: Set<String> = []
        let value = apps
            .filter { selectedIDs.contains($0.bundle.id) }
            .filter { entry in
                guard seen.insert(entry.bundleID).inserted else { return false }
                return isAppRunning(entry.bundleID)
            }
            .map(\.name)
        runningAppsCache = (stateRevision, value)
        return value
    }

    /// Apps whose bundle is checked but whose leftover files aren't all
    /// checked, one entry per app: uninstalling only the bundle would leave
    /// those files on disk, and the confirmation sheet warns and offers the
    /// one-click catch-up.
    var unselectedResidues: [AppResidueSummary] {
        if let cached = unselectedResiduesCache, cached.key == stateRevision { return cached.value }
        let value = apps.compactMap { entry -> AppResidueSummary? in
            guard selectedIDs.contains(entry.bundle.id) else { return nil }
            let pending = entry.residues.filter { !selectedIDs.contains($0.id) }
            guard !pending.isEmpty else { return nil }
            return AppResidueSummary(
                appName: entry.name,
                count: pending.count,
                size: pending.reduce(0) { $0 + $1.size }
            )
        }
        unselectedResiduesCache = (stateRevision, value)
        return value
    }

    /// Adds every leftover file of the checked apps to the selection (the
    /// confirmation sheet's one-click action), leaving unrelated checks
    /// alone.
    func selectResiduesForSelectedApps() {
        for entry in apps where selectedIDs.contains(entry.bundle.id) {
            selectedIDs.formUnion(entry.residues.map(\.id))
        }
    }

    /// The real icon of an app bundle, cached per path. nil for anything
    /// without a path; the view falls back to a category symbol.
    func icon(forPath path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        if let cached = iconCache[path] { return cached }
        let icon = iconForPath(path)
        iconCache[path] = icon
        return icon
    }

    // MARK: Selection actions

    /// Checks or unchecks one residue file.
    func setResidueSelected(_ item: JunkItem, selected: Bool) {
        if selected {
            selectedIDs.insert(item.id)
        } else {
            selectedIDs.remove(item.id)
        }
    }

    /// The app row's checkbox: all-or-nothing over the bundle and every
    /// leftover file. A partially checked app clicking its box checks the
    /// rest — the gesture reads as "uninstall this app completely", which is
    /// what the row's size already promised.
    func setAppSelected(_ entry: AppEntry, selected: Bool) {
        if selected {
            selectedIDs.formUnion(entry.allIDs)
        } else {
            selectedIDs.subtract(entry.allIDs)
        }
    }

    /// Checks exactly one app's bundle and residue files, dropping every
    /// other check — the context menu's "uninstall this app" gesture, which
    /// targets exactly these items.
    func selectApp(_ entry: AppEntry) {
        selectedIDs = Set(entry.allIDs)
    }

    /// Checks exactly one app's residue files, keeping the app itself
    /// installed — the context menu's "clean leftover files only" gesture.
    func selectAppResidues(_ entry: AppEntry) {
        guard !entry.residues.isEmpty else { return }
        selectedIDs = Set(entry.residues.map(\.id))
    }

    // MARK: Uninstall flow

    /// Opens the confirmation sheet for the current selection.
    func requestUninstall() {
        guard !selectedItems.isEmpty, phase == .idle else { return }
        phase = .confirming
    }

    func cancelConfirmation() {
        guard phase == .confirming else { return }
        phase = .idle
    }

    /// Runs the clean over the selection. `moveToTrash` is the shared
    /// setting's current value, passed in per call so the tool never owns a
    /// second copy of it.
    func beginClean(moveToTrash: Bool) {
        guard phase == .confirming, !selectedItems.isEmpty else { return }
        // A second clean replaces the first rather than racing it: two
        // engines deleting overlapping paths would report each other's
        // outcomes.
        cleanTask?.cancel()
        let targets = selectedItems
        phase = .cleaning
        progress = 0
        outcomes = []
        cleanedCount = 0
        currentTitle = ""
        pendingRemoval = []
        cleanStartedAt = .now
        MackitLog.apps.info("uninstall started: \(targets.count, privacy: .public) entries, move to Trash \(moveToTrash, privacy: .public)")

        cleanTask = Task { [clean] in
            let stream = clean(targets, moveToTrash)
            for await event in stream {
                if Task.isCancelled { return }
                self.applyClean(event)
            }
        }
    }

    private func applyClean(_ event: CleanEvent) {
        switch event {
        case .started(let total):
            progress = total > 0 ? 0 : 1
            pendingRemoval = []
            currentTitle = L10n.tr("clean.preparing")

        case .progress(let completed, let total, let current):
            progress = total > 0 ? Double(completed) / Double(total) : 0
            currentTitle = current

        case .outcome(let outcome):
            outcomes.append(outcome)
            if outcome.succeeded {
                cleanedCount += 1
                pendingRemoval.insert(outcome.itemID)
            }

        case .finished(let reclaimed, let failures):
            self.reclaimed = reclaimed
            self.failures = failures
            progress = 1
            phase = .done
            movedToTrash = outcomes.contains { $0.movedToTrash }
            for outcome in outcomes where !outcome.succeeded {
                MackitLog.apps.error("uninstall failed \"\(outcome.title, privacy: .public)\": \(outcome.message, privacy: .public)")
            }
            if let startedAt = cleanStartedAt {
                MackitLog.apps.info("uninstall finished: freed \(reclaimed, privacy: .public) bytes, \(failures, privacy: .public) failures, took \(MackitLog.duration(.now - startedAt), privacy: .public)")
                cleanStartedAt = nil
            }
            // Removed in one batch: the uninstalled apps leave the list and
            // the result card takes the page's place.
            removeCleanedItems(pendingRemoval)
            pendingRemoval = []
        }
    }

    /// Drops the cleaned items from the list in one batch.
    ///
    /// An app whose bundle was removed is gone entirely — it is no longer
    /// installed, so listing it would be a lie — and the residue files of
    /// its that failed to delete leave the list with it: they are still on
    /// disk, orphaned, and the result card's failure list names them with
    /// the reason. Their checks are dropped too, since nothing in the list
    /// matches them any more.
    ///
    /// An app whose bundle clean failed stays listed with its remaining
    /// residue files, and the failed items stay checked so they can be
    /// retried; only items that actually left the disk lose their check.
    private func removeCleanedItems(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        apps = apps.compactMap { entry in
            guard !ids.contains(entry.bundle.id) else {
                selectedIDs.subtract(entry.residues.map(\.id))
                return nil
            }
            return AppEntry(bundle: entry.bundle, residues: entry.residues.filter { !ids.contains($0.id) })
        }
        selectedIDs.subtract(ids)
    }

    /// Stops the clean, keeping whatever it already removed in the list —
    /// the same contract the cleanup scan's cancel has.
    func cancelClean() {
        // Only a running clean can be cancelled: the stop button lives in
        // the cleaning overlay, and a stale call after the result card is up
        // would throw the finished result away.
        guard phase == .cleaning else { return }
        cleanTask?.cancel()
        cleanTask = nil
        if !pendingRemoval.isEmpty {
            let alreadyRemoved = pendingRemoval.count
            removeCleanedItems(pendingRemoval)
            pendingRemoval = []
            MackitLog.apps.info("uninstall cancelled by user: \(alreadyRemoved, privacy: .public) completed entries removed from the list")
        } else {
            MackitLog.apps.info("uninstall cancelled by user: no completed entries")
        }
        outcomes = []
        progress = 0
        cleanedCount = 0
        currentTitle = ""
        cleanStartedAt = nil
        phase = .idle
    }

    /// Leaves the result card for the list.
    func dismissResult() {
        guard phase == .done else { return }
        phase = .idle
    }

    /// Test seam: waits until no scan or clean is in flight. Same polling
    /// contract as the other tools' models.
    func waitUntilSettled() async {
        while isLoading || phase == .cleaning {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A summary of an app's leftover files that are not checked.
struct AppResidueSummary: Equatable, Hashable, Sendable {
    let appName: String
    let count: Int
    let size: Int64
}
